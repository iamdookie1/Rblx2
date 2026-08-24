# Centrl UI (`Lib2.lua`)

A code-built recreation of the Centrl panel, with mobile support. Independent of
`Library.lua` — the two libraries share nothing and can be loaded side by side.

This is the copy every script in this repo loads. On top of the published
library it carries the top tab strip and the native unibar (topbar) show/hide
icon, both patched in at the bottom of the file.

```lua
local Centrl = loadstring(game:HttpGet('https://raw.githubusercontent.com/iamdookie1/Rblx2/main/UI/Lib2.lua'))()

local Window = Centrl:Window({
    Title      = 'centrl',
    SubTitle   = 'v2',
    Folder     = 'centrl',                       -- config folder
    ToggleKey  = Enum.KeyCode.RightShift,
    Accent     = Color3.fromRGB(227, 255, 42),
    Scale      = 1,                              -- multiplies the auto-fit scale
    SettingsTab = true,                          -- built-in settings tab
    MobileButton = true,                         -- floating open/close button on touch
    IconApi    = 'https://your-deployment.vercel.app',  -- Lucide icon API
})

local Tab = Window:Tab({ Title = 'legit', Icon = 'crosshair' })
local Sec = Tab:Section({ Title = 'aimbot', Side = 'left' })  -- 'left' | 'right'

Sec:Toggle({ Title = 'enabled', Flag = 'aim', Callback = function(state) end })

Window:Load()
```

See [`Example2.lua`](Example2.lua) for a script that uses every element.

## Window

| Method | Description |
|---|---|
| `Window:Tab({ Title, Icon })` | Adds a rail tab, returns a Tab |
| `Window:GetTab(title)` | The rail tab with that title, or nil |
| `Window:SelectTab(title)` | Brings that rail tab forward |
| `Window:Load()` | Loads the saved config and opens the window |
| `Window:SetVisible(bool)` | Show / hide the whole panel |
| `Window:SetOpen(bool)` | Expand / collapse to the topbar |
| `Window:SetToggleKey(keycode)` | Change the show/hide key |
| `Window:SetTitle(text)` | Rename the header |
| `Window:Destroy()` | Remove the UI and every connection |

Library-level: `Centrl:SetAccent(color)`, `Centrl:SetScale(n)`, `Centrl:Notify{}`,
`Centrl:Watermark{}`, `Centrl:SaveConfig(name)`, `Centrl:LoadConfig(name)`,
`Centrl:ListConfigs()`, `Centrl:DeleteConfig(name)`, `Centrl.Flags`.

## Elements

All live on a Section and all accept `Title`, `Flag` and `Callback`.

| Element | Extra options |
|---|---|
| `Section:Toggle{}` | `Default` |
| `Section:Slider{}` | `Min`, `Max`, `Increment`, `Default`, `Suffix` |
| `Section:RangeSlider{}` | `Min`, `Max`, `Increment`, `Default`, `Suffix` — two knobs, one track |
| `Section:Dropdown{}` | `Options`, `Default`, `Multi`; `:SetOptions{}` |
| `Section:Textbox{}` | `Placeholder`, `Default`, `ClearOnFocus` |
| `Section:Keybind{}` | `Default`, `ChangedCallback` |
| `Section:Colorpicker{}` | `Default` — SV square, hue bar, HEX + RGB entry, rainbow, copy |
| `Section:Button{}` | — |
| `Section:Label{}` / `Section:Paragraph{}` / `Section:Divider{}` | `Text` |
| `Section:Progress{}` | `Min`, `Max`, `Default`, `Suffix`, `Percent`, `ShowMax`, `Color`, `Format` |
| `Section:Buttons{}` | An array of buttons laid out on one row |
| `Section:Stat{}` | `Value`, `Color` — name left, live value right |
| `Section:Console{}` | `Height`, `MaxLines`, `Timestamps`, `Monospace`, `AutoScroll` |
| `Section:Image{}` | `Image`, `Height`, `Transparency`, `ScaleType` |

A Section itself has `:SetTitle(text)`, `:SetVisible(bool)`, `:Clear()` (drops
every element but keeps the card) and `:Destroy()`.

Every element returns a manager with `:Set(value)` and `:Get()`. Pass
`IgnoreSaved = true` to keep an element out of the config file.

### Range slider

For a setting that is a span rather than a point — a delay picked somewhere
between 0.5s and 0.7s, a distance band, a damage roll:

```lua
local delay = Section:RangeSlider({
    Title = 'shot delay',
    Flag = 'aim_delay',
    Min = 0, Max = 2, Increment = 0.05,
    Default = { 0.5, 0.7 },   -- or DefaultMin = 0.5, DefaultMax = 0.7
    Suffix = 's',
    Callback = function(low, high) end,
})

delay:Get()        --> 0.5, 0.7
delay:GetRange()   --> { Min = 0.5, Max = 0.7 }
delay:Random()     --> a number inside the span
delay:Set(0.4, 0.9)
delay:SetMin(0.4)  -- moves one edge, leaves the other
```

The knobs cannot cross: dragging one past the other stops it at its partner.
Grab anywhere on the track and the nearer knob comes to you; press outside the
span and the knob on that side moves, which is also how two knobs sitting on the
same value get pulled back apart.

`Flags[flag]` holds `{ Min = , Max = }`, and that table saves and loads with the
rest of the config. `:Set()` accepts the same table, so `slider:Set(Flags.aim_delay)`
works directly.

Option keys are read case-insensitively across common spellings (`Title`/`title`,
`Callback`/`callback`, `Min`/`minimum_value`, …), and the old lowercase call names
(`create_toggle`, `create_slider`, …) are aliased to the new ones.

## Tabs inside tabs

A rail tab can host its own row of tabs instead of one long wall of sections, so
one rail slot carries several real pages:

```lua
local combat = Window:Tab({ Title = 'combat', Icon = 'swords' })

local melee  = combat:Tab({ Title = 'melee', Icon = 'sword' })
local ranged = combat:Tab({ Title = 'ranged' })

melee:Section({ Title = 'combos', Side = 'left' }):Toggle({ Title = 'auto' })
ranged:Section({ Title = 'aim', Side = 'right' }):Slider({ Title = 'fov' })
```

A sub-tab is a tab in every way that matters: its own two columns, its own
sections, its own selection. It just lives in a horizontal strip at the top of
its parent's page rather than on the rail.

| Method | Description |
|---|---|
| `Tab:Tab({ Title, Icon })` | Adds a sub-tab, returns it |
| `Tab:GetTab(title)` / `Tab:SelectTab(title)` | Look one up / bring it forward |
| `subtab:Select()` | Swap to it inside the parent page |
| `subtab:Focus()` | Select the parent rail tab too, then this page |
| `:SetTitle(text)` / `:SetIcon(icon)` / `:SetBadge(text)` | On tabs and sub-tabs alike |

`SetBadge` puts a short accent pill on the tab button — an unread count, a live
`'3 on'`, a `'!'`. Pass `nil` to hide it again.

Mixing the two styles works. Sections added to a tab **before** its first
sub-tab exists migrate into that sub-tab, keeping the side they were on, and a
`tab:Section(...)` afterwards lands on whichever sub-page is currently showing.
So this produces one coherent page, not content stranded on a hidden layer:

```lua
local tab = Window:Tab({ Title = 'main' })
tab:Section({ Title = 'always here' })   -- ends up on 'general'
local general = tab:Tab({ Title = 'general' })
local extra   = tab:Tab({ Title = 'extra' })
```

## Progress, stats and logs

```lua
local bar = Section:Progress({ Title = 'charge', Percent = true })
bar:Set(62)                      -- animates
bar:SetText('idle')              -- pin the readout, nil hands it back
bar:SetColor(Color3.new(1,0,0))  -- opts out of following the theme accent

local fps = Section:Stat({ Title = 'fps', Value = 60 })
fps:Set(31, Color3.fromRGB(255, 196, 87))

Section:Buttons({
    { Title = 'start', Callback = start },
    { Title = 'stop',  Callback = stop },
})   --> { buttonApi, buttonApi }

local log = Section:Console({ Title = 'log', Height = 110, MaxLines = 60, Timestamps = true })
log:Add('waiting')          -- also :Success / :Warn / :Error / :Info
log:Clear()
log:Get()                   --> array of line strings
```

`Console` caps how many lines exist as instances and destroys the oldest past
`MaxLines`, so a log left running for an hour stays flat rather than growing
without bound. It follows the newest line unless you turn that off with
`:SetAutoScroll(false)`.

## Icons

Anywhere an `Icon` is accepted you can pass a [Lucide](https://lucide.dev) name
(`'house'`, `'ArrowRight'`, `'arrow-right'`), a bare asset id (`'6034509993'`) or a
full `rbxassetid://` string. Asset ids are set directly; Lucide names hit the icon
API in [`iamdookie1/web3`](https://github.com/iamdookie1/web3) —
`GET /icon?name=house&size=64&format=alpha8` — and the response is turned into a
real icon like this:

1. `payload.data` (base64) is decoded into raw bytes — one coverage byte per pixel,
   row-major, top-left origin, exactly as the API describes it.
2. `payload.width` / `payload.height` — **read from the response, not assumed** —
   size the `EditableImage`, so a mismatched or clamped server-side size (the API
   clamps to 1–1024) still renders correctly instead of reading out of bounds.
3. Each byte becomes one pixel's alpha channel in an RGBA buffer, RGB left white,
   and the buffer is written to the image in one `WritePixelsBuffer` call.
4. The `ImageLabel`/`ImageButton` gets `ImageContent = Content.fromObject(image)`.

Every icon in the panel is tinted via `ImageColor3` rather than baked into the
fetch, so the same white source image serves every accent colour and every theme
change — no re-fetch, just a property flip.

### What `size` changes

`GET /icon?name=house&size=64` renders the icon at exactly 64×64 source pixels —
`size` is the rendered resolution of what gets fetched, not the size it displays
at on screen; those are set independently (the `ImageLabel`'s own `Size`).
Requesting **larger** than the display size costs more bytes (`byteLength` grows
with the square of `size`) for no visible gain — downscaling a big source to a
small frame looks identical to requesting the small size directly, since Roblox
filters on the way down. Requesting **smaller** than the display size is the one
that actually costs quality: the source gets stretched up to fill the frame and
visibly blurs / pixelates, exactly as the `iamdookie1/web3` README warns.

The panel exploits the first half of that trade-off for crispness headroom: every
built-in icon (tabs, the topbar logo, minimise/close, the mobile button) requests
**roughly twice its on-screen size**, not a flat default. The window's own
`UIScale` can run up to 2×, so a 16px tab icon requests at 32px — big enough to
stay sharp at maximum zoom, without fetching a wastefully large 64px source for
something that never displays past 32px. `Padding` scales down to match (the
API's 4–6px suggestion is sized for 64px icons and would eat a visible chunk out
of a 16px one), so small glyphs don't shrink inside their own frame.

```lua
Centrl:SetIconSource('https://your-deployment.vercel.app')  -- or Window{ IconApi = ... }
Centrl.Icons.Size = 64        -- default render resolution for calls that don't override it
Centrl.Icons.StrokeWidth = 2
Centrl.Icons.Padding = 4      -- keeps round caps off the frame edge
Centrl.Icons.Enabled = false  -- ignore Lucide names entirely
Centrl:ApplyIcon(myImageLabel, 'sword')                        -- never yields
Centrl:ApplyIcon(myImageLabel, 'sword', { Size = 48 })         -- override per call
Centrl:GetIcon('sword')                                        -- yields, returns the EditableImage
```

Results are cached per name + size + stroke + padding, so calling the same icon at
the same options twice — including the automatic tab/control sizing above — costs
one fetch, not two.

Fetching happens on the client — an executor has HTTP there, so there's no
`RemoteFunction` hop like the `roblox/LucideIcons.lua` module in that repo needs.
It needs `AssetService:CreateEditableImage`; where that's unavailable, or when the
API can't be reached, the icon is skipped with one warning and everything else
still works. `Centrl:ClearIconCache()` (also called automatically by
`SetIconSource` and `Unload`) destroys every cached `EditableImage` rather than
just dropping the table, so switching deployments or tearing down the UI doesn't
leak instances.

`Icons.BaseUrl` defaults to `https://web3-six-beta.vercel.app`, the deployment this
library ships against. Point it elsewhere with `Icons.BaseUrl`/`IconApi` if you run
your own.

The topbar's own minimise (`chevron-up`/`chevron-down`, flips with state) and close
(`x`) controls are Lucide icons too, not the placeholder text glyphs from the first
cut of this library.

## Configs

Flags auto-save per game to `<Folder>/<GameId>.json` whenever a value changes, and
`Window:Load()` reads them back through each element's own setter. Named configs go
to `<Folder>/configs/<name>.json` and are managed from the settings tab. Color and
keycode flags are boxed so they survive the JSON round trip.

## Position

The window is anchored top-left rather than centered, so collapsing to the topbar
and expanding again leave the header exactly where it was — a centered anchor moves
the top edge by half of every height change, which is what made the panel creep up
the screen each time it reopened. Minimising and closing are also tracked as two
separate, independent states (`Open` vs `Visible`): hiding the panel and reshowing
it restores whichever of the two it was actually left in, instead of always
snapping back open.

Clamping to the viewport isn't event-driven — it's wired to the window's own
`AbsoluteSize` and `Position`, so it fires on every single change to either one:
every frame of a drag, every frame of the open/collapse tween (not just once it
lands), a scale change, a viewport resize. Nothing can put the panel off-screen
even momentarily, because there's no path that changes its size or position without
also running the clamp immediately afterward. The floating mobile button is wired
the same way. Neither can end up off screen, instantly or otherwise.

## Mobile

- The panel scales itself to the viewport on every device and never scales up.
  Touch devices target a smaller share of the screen than desktop, because a phone
  viewport is wide enough in GUI pixels to "fit" the panel at an unusable size.
- Columns stack into a single full-width column on touch, and rows, checkboxes,
  slider bars and hit targets all grow.
- Sliders and the color picker read the input's own position, not `Mouse.X`, so a
  finger drags them exactly like a mouse. Reading the mouse would peg them to their
  minimum on every tap.
- One control owns a drag at a time, so a finger sliding down the panel can't pick
  up every slider it crosses. Ownership is force-released on input end, so a finger
  that leaves a control's bounds before lifting doesn't wedge the panel.
- The window drags from the topbar and the tab rail only; scrolling regions sink
  touch input so a drag over content scrolls instead of moving the window.
- Dropdown and colorpicker bodies expand inline rather than floating, so nothing
  gets clipped by the scrolling column and the page still scrolls while they're open.
- A draggable floating button opens the panel where there's no keyboard; tapping it
  toggles, dragging it moves it, and it shrinks slightly on press for tactile
  feedback. Its icon defaults to the Lucide `menu` icon — override with
  `Window{ MobileButtonIcon = 'name' }`. Keybind elements say so instead of hanging
  when there's no keyboard to listen for.

## Notes

- Works in executors (`gethui`, `cloneref`, file API) and degrades in Studio, where
  configs simply don't persist.
- `Centrl:Notify({ Title, Content, Type = 'success' | 'error' | 'warning' | 'info', Duration })`.

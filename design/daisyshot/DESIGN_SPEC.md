# Daisyshot — Design Spec (rebrand from Bestshot)

This folder is the hand-off for re-skinning the existing macOS app (currently "Bestshot") with the Daisyshot identity.
**Scope: visual re-skin + rename. No feature or behaviour changes**, except the small additions listed in §8.

Source of truth for exact values: the HTML mockups in `reference/html/` (every colour, size and radius is written inline there).
Canvas with all boards: https://claude.ai/code/artifact/64ffe99f-04c5-415f-8b6c-5edc47eaed2c

---

## 1. Brand idea

- Name: **Daisyshot**. Daisy = a fresh, friendly flower; its centre = "tâm" (the centre / the aim point).
- Mark: a geometric daisy whose 8 petals are the 8 resize handles of a selection frame (4 diagonal petals reach the corners, 4 straight petals reach the edge mid-points). Yellow centre = the aim point.
- Personality: bright, tidy, friendly, precise, a little playful. Not childish, not cold-tech.
- Product promise shown in UI: **runs fully offline — nothing leaves your Mac.**

## 2. Colour tokens

| Token | Light | Dark (derived, not mocked) | Use |
|---|---|---|---|
| `accent` (Sky 500) | `#3E7BFA` | `#4A86FF` | toggles on, checkboxes, slider fill, selected rings, focus |
| `accentStrong` (Sky 600) | `#2B5FE0` | `#5B93FF` | primary button fill, highlighted menu row, links |
| `accentText` | `#1A3FA8` | `#A9C7FF` | text on accent-tint backgrounds (selected sidebar row, keycaps) |
| `accentTint` | `#DCE7FF` | `#23365F` | selected sidebar row background, section-icon tile |
| `skyLight` | `#7FB8FF` | `#7FB8FF` | icon gradient top, About tile |
| `center` (Nhụy yellow) | `#FFC633` | `#FFC633` | brand accent only: daisy centre, recording dot, i-dot |
| `centerDeep` | `#F5A21B` | `#F5A21B` | yellow on white backgrounds (needs ≥ 3:1 for non-text only) |
| `leaf` | `#2FA57A` | `#3DBB8C` | success / "Offline · Private" / "On-device" chips |
| `leafTint` / `leafText` | `#E3F4EC` / `#1F6E52` | `#173A2E` / `#8FDCBC` | chip background / chip text |
| `ink` | `#101A33` | `#F2F3F7` | primary text |
| `inkSecondary` | `#55617A` | `#AEB9D3` | secondary text, captions, sub-labels |
| `inkTertiary` | `#8A93A8` | `#7D879D` | disabled labels, shortcut hints |
| `windowBg` | `#FFFFFF` | `#1B2133` | settings content area |
| `sidebarBg` | `#EEF2F8` | `#151B2B` | settings sidebar |
| `cardBg` | `#F5F7FB` | `#222A3D` | grouped rows card |
| `separator` | `#E6EAF1` | `#2E374D` | row dividers |
| `controlBorder` | `#DDE2EB` | `#3A4560` | buttons, pop-ups, inputs |
| `toggleOff` | `#D5DBE5` | `#3A4560` | toggle track off, slider track |
| `destructive` | `#B42318` | `#FF7A6E` | destructive button text (Clear History…) |
| Annotate default colour | `#E5484D` | — | default stroke colour (kept red) |

Prefer semantic system colours where macOS already has them (window background, label colours) and use these tokens for brand surfaces. Dark values above are a starting point; check contrast (text ≥ 4.5:1).

## 3. Typography

- UI text: system font (SF Pro). Body 14 px/pt, sub-labels 12.5, captions 12, page title 20 semibold, section header 15 bold.
- Keycaps & code: SF Mono / `ui-monospace`, 12–13 pt.
- The **logotype is an asset** (`assets/logo/logotype-*.svg`, outlined Sora SemiBold with a yellow i-dot). Never re-typeset it with a font.

## 4. Metrics (settings window)

- Window ≈ 1040 pt wide; sidebar 250 pt; content padding 22 top / 36 sides / 32 bottom; vertical gap 16 between cards.
- Card: radius 12, horizontal padding 16, rows min-height 48 (Shortcuts rows 42), 1 px separator between rows.
- Sidebar row: padding 7×10, radius 9, gap 10; icon tile 26×26, radius 7, glyph 16 pt white (ink on yellow tile).
- Selected sidebar row: `accentTint` background, `accentText` label, semibold (not the solid-blue default).
- Toggle: 42×24 track, 20 pt knob. Checkbox 20×20 radius 6. Pop-up button: white, 1 px `controlBorder`, radius 7, chevron up/down 12 pt.
- Buttons: secondary = white + border, radius 8, padding 6×14; primary = `accentStrong` fill, white text.
- Slider: 4 pt track `toggleOff`, fill `accent`, 20 pt white knob with soft shadow; optional tick dots `#B4BCCB`.
- Segmented control: track `#E6EAF1` radius 8, selected segment white with shadow, label `accentText` semibold.

## 5. Sidebar icons (tile colour → suggested SF Symbol)

| Item | Tile | SF Symbol suggestion |
|---|---|---|
| General | `accent` | `gearshape` (or a small daisy glyph) |
| Shortcuts | `accentStrong` | `command` |
| Quick Access Overlay | `inkSecondary` | `rectangle.stack` |
| Wallpaper | `leaf` | `photo` |
| Screenshots | `accent` | `viewfinder` |
| Screen Recording | `center` (ink glyph) | `record.circle` |
| Annotate | `ink` | `arrow.up.right` |
| Advanced | `inkSecondary` | `slider.horizontal.3` |
| About | `skyLight` (ink glyph) | `info` |

## 6. App icon

- Default: **Handles** (`assets/app-icon/handles`). Alternates selectable in Settings › General › Appearance: **Crosshair** (`crosshair`) and **Viewfinder** (`viewfinder`).
- Each variant folder has: `AppIcon.appiconset` (ready for Xcode), `icon-1024.png`, full SVGs, and separate layers `layer-background.svg` + `layer-foreground-flat.svg` for building a macOS 26 `.icon` in Icon Composer (Composer adds the glass depth; the flat foreground has no baked shadows). 16/32 px slots use the simplified "small" drawing.
- Runtime switching: set `NSApp.applicationIconImage` from the chosen asset at launch and when the setting changes (affects the Dock/app switcher while running). Finder/Launchpad keep the bundle icon; don't modify the signed bundle.

## 7. Menu bar (status item)

- Normal: `assets/menubar/menubar-black.svg` (18×18 pt, 6-petal daisy inside 4 viewfinder corners, hollow centre) as a **template image** (`isTemplate = true`).
- Recording indicator setting (General › Appearance):
  - **Monochrome** (template): `menubar-rec-black` — centre becomes a solid dot.
  - **Yellow centre** (default in mockup, NOT template): `menubar-rec-yellow-black` on light menu bar, `menubar-rec-yellow-white` on dark; pick by `effectiveAppearance`.
- Recording time shown left of the icon when "Display recording time in menu bar" is on.
- PNG @1x/@2x are included if the asset catalog needs bitmaps; prefer the SVG with "Preserve Vector Data".

### Status-item menu (see `reference/html/UIMenu.dc.html`)
Header row: logotype (~104 pt wide) + leaf chip "Offline · Private". Then groups, separated:
1. All-In-One ⌥⇧⌘5 · Capture Area ⌥⇧⌘4 · Capture Previous Area ⌥⇧⌘7 · Capture Fullscreen ⌥⇧⌘3 · Capture Window ⌥⇧⌘W · Scrolling Capture ⌥⇧⌘8 · Self-Timer · Capture Text ⌥⇧⌘2
2. Record Screen ⌥⇧⌘6 (icon: ring + yellow centre dot)
3. Hide Desktop Icons ⌥⇧⌘D
4. Open… · Open from Clipboard · Pin to the Screen…
5. Capture History… · Restore Recently Closed ⌥⇧⌘Z
6. About Daisyshot · 7. Settings… ⌘, · 8. Quit Daisyshot ⌘Q
Highlighted row uses `accentStrong`. All-In-One may use the brand mark glyph.

## 8. Per-screen notes (what changes vs. Bestshot)

Same content, order and defaults as today unless stated. Mockups: `reference/html/Settings*.dc.html`.

- **General** — new card "Appearance": *App icon* picker (3 tiles: Handles = Default, Crosshair, Viewfinder; selected = 2 pt `accent` ring), *Show menu bar icon* (moved here, with the glyph), *Recording indicator* segmented (Monochrome / Yellow centre). Export location caption adds "Files never leave this Mac." (copy to confirm).
- **Shortcuts** — section headers get a small `accentTint` icon tile; set shortcuts render as keycaps (white, 1 px border + 2 px bottom border, mono, `accentText`); unset = dashed ghost button "Record shortcut" (hover → accent); clear = small round × button. Same list and defaults.
- **Quick Access Overlay** — "Shortcuts on a hovered overlay" and "Gestures" become wrapped keycap chips instead of one long line; Left/Right segmented control.
- **Wallpaper** — "Plain color" offers brand swatches (white, `#F5F8FF`, sky, leaf, yellow, ink, +custom), dimmed until selected.
- **Screenshots** — "Sensitive info (Auto Redact)" header gets a leaf "On-device" chip; Redaction style pop-up shows a tiny swatch; window background options are 100×64 thumbnails with an accent ring when selected.
- **Screen Recording** — "Display recording time in menu bar" shows a tiny preview chip (icon + 00:42).
- **Annotate** — default colour row = swatches (red default, yellow, sky, leaf, ink, white, +); a preview box shows the arrow and "Aa" at the current line width / font size.
- **Advanced** — file-name example and URL-scheme examples in mono "code" pills; "Clear History…" uses `destructive` text.
- **About** — icon framed by 4 faint viewfinder corners (`#BFD3F7`), logotype asset, version, description, leaf chip "Runs fully offline. Nothing leaves your Mac.", primary button "Welcome Guide…", footer "© 2026 Daisyshot. All Rights Reserved."

## 9. Rename checklist (Bestshot → Daisyshot)

- Display name, menu items (About/Quit), About window, window titles, alerts, onboarding.
- Default file-name prefix: `Daisyshot 2026-10-08 at 17.14.01.png`.
- URL scheme: add `daisyshot://`; **keep `bestshot://` working** as an alias for existing users/integrations.
- **Do NOT change the bundle identifier** without a migration plan: it resets Screen Recording/Accessibility permissions, UserDefaults, Login Item and keychain items for every user.
- Search the codebase for "Bestshot"/"bestshot" (strings, Info.plist, localisation files, asset names, help text).

# Daisyshot — Record setup overlay spec

Scope: only the Record Screen setup overlay. The rest of the app (brand, tokens, Settings, menu) is already implemented — reuse the existing Daisyshot tokens and components; the token table below is for reference only.

## Record setup overlay (Record Screen flow) — NEW LAYOUT

Full numbers: `reference/html/RecSpec.dc.html` (specs + rationale) and `RecParts.dc.html` (every state). Behaviour reference: `RecPrep.dc.html` (one component; the `Rec*Light/Dark.dc.html` files only import it with a theme + mode). This replaces the old two-bar layout (source bar + record bar).

Final decisions from the owner (override anything older in the HTML text):
- **Always records in Studio mode.** No GIF | Studio switch before recording; GIF is chosen at export time.
- **No cursor button and no keystrokes button** before recording. Keystrokes are always captured; showing them is decided in the editor.
- **No record bar under the selection.** After a source is chosen, a **Start card** appears in the middle of the target.

### 1 Overlay
- Whole screen dimmed with black 40% (Device mode 55%). Outside a selected area/window stays dimmed; inside is clear.
- Glass material for the bar and the card: macOS 26 Liquid Glass if available (`glassEffect` — verify API name), fallback `NSVisualEffectView` (.hudWindow dark / .popover light) + fill `#1C202C @ 50%` (dark) / `#FAFBFE @ 52%` (light), blur ≈ 24, saturate 1.8; 1 pt border white 18% / 55%; top inner highlight white 16% / 90%; shadow 0 12 32 black 45% (dark) / #101A33 28% (light). Follow system appearance; Dark is the recommended fixed default.

### 2 Source bar (top centre, 12 pt below the menu bar)
Height 64, radius 16, padding 6. Left → right: Cancel (xmark in a 28 pt disc) · | · **Screen · Window · Area · Device** (tiles min 64 × 52, icon 20 above an 11 pt label, radius 10; selected = accentTint bg + accentText) · | · **Camera · Microphone · System audio** (tiles min 76 / max 124, label truncates at 108 with tooltip; on = accentText label + accent icon; mic shows a 56 × 3 live level meter, leaf #2FA57A, red #E5484D above 85%) · | · Settings (gearshape).
SF Symbols: display, macwindow, rectangle.dashed, ipad.and.iphone, video(.slash), mic(.slash), speaker.wave.2 / speaker.slash, gearshape, xmark.

### 3 Start card (replaces the record bar)
Width 340, padding 16, radius 18, gap 14, same glass. Contents only:
1. Header: 40 × 40 icon tile (radius 10; Window mode = the real app icon) + name 15 semibold (truncate) + sub-line 12 pt secondary (resolution etc.); optional chip "Display 1 of 2".
2. Output size button (full width, height 32, radius 8, `aspectratio` icon + "Original · 1512 × 982" / "16:9 · 848 × 477" + chevron) → preset menu.
3. **Start Recording** button: full width, height 44, radius 12, accentStrong #2B5FE0, yellow dot #FFC633 (12 pt + 3 pt halo), 15 pt semibold white, small "↩" hint. Return starts recording.
Placement:
- Screen: centre of each display. Multiple displays → one card per display; display under the cursor gets a 4 pt accent outline and full-opacity card, others 85%.
- Window: centre of the hovered window (follows hover with a spring); header shows app icon + window title. If the window is smaller than the card, put the card below it (14 pt gap), else above.
- Area: centre of the area when ≥ 380 × 300, otherwise below / above / right of it. Hidden while dragging.
- Device (iPhone/iPad): to the right of the live device preview (40 pt gap), vertically centred.
Optional (owner to confirm): fade the card to 30% when the pointer leaves it for 1 s.

### 4 Selection frame
1 pt dark outline + 1.5 pt white dashed line; 8 **petal handles** (white capsules 16 × 6, corners rotated ±45°, offset 4 outward, 24 pt hit area; hover = 20 × 8 accent fill with white border); yellow 9 pt centre dot; size label pill (#101A33 @ 88%, 12 pt semibold white, preset in yellow) above the top-left corner. While dragging: hide handles, dot and card; show rule-of-thirds grid; label follows the cursor. Window/Screen hover: 3 pt (screen 4 pt, inset) accent outline + accent 12% (8%) fill.

### 5 Device source (new feature: record iPhone / iPad)
- Picker menu under the Device tile: device name + connection (USB-C / Wi-Fi), Orientation (Auto / Portrait / Landscape), Show device frame, help text "Connect the device, unlock it and tap Trust".
- Live preview centred-left, 620 pt tall, true aspect ratio, dark rounded frame (generic, not Apple product artwork). Label: green dot + name + native resolution.
- Audio tile becomes "No device audio" / "iPhone audio". Mic and camera stay the Mac's.
- Implementation hint (verify): wired iOS screen capture is normally exposed by enabling CoreMediaIO screen-capture devices (`kCMIOHardwarePropertyAllowScreenCaptureDevices`) and then using the device as an `AVCaptureDevice` (muxed audio+video). Wi-Fi capture needs a separate investigation.

### 6 Keyboard
Esc cancel · Space toggles Window ⇄ Area · Return start · ⌘1/2/3/4 Screen/Window/Area/Device · arrows nudge the area 1 pt (⇧ 10 pt) · Tab: source bar → Start card (→ next display's card).


## Reference files

| File | Content |
|---|---|
| RecPrep.dc.html | The whole overlay as one component, all modes (the source of truth for layout and values) |
| RecAreaEmpty*, RecArea*, RecWindow*, RecScreen*, RecDevice* (Light/Dark) | The overlay in each situation (they only import RecPrep with a theme + mode) |
| RecParts.dc.html | Every component state |
| RecSpec.dc.html | Measurements, colours, SF Symbols, placement rules, rationale |

---

## Appendix · colour tokens (already in the app)

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


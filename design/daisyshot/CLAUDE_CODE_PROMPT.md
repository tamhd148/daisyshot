Copy everything below the line into Claude Code (run it from the root of the app's repository, after copying this folder to `design/daisyshot/`).

---

We are rebranding this macOS app from "Bestshot" to "Daisyshot". The full design hand-off is in `design/daisyshot/`:

- `design/daisyshot/DESIGN_SPEC.md` — brand, colour tokens (light/dark), typography, metrics, per-screen changes, rename checklist. Read it fully first.
- `design/daisyshot/reference/html/*.dc.html` — HTML mockups of every screen (status-item menu and all Settings panes). Exact colours, sizes and radii are inline in the markup; treat them as the visual source of truth. Ignore the `<x-dc>`, `<sc-for>`, `<sc-if>` tags and the script block — they are only the mockup tool's templating.
- `design/daisyshot/assets/` — app icons (3 variants with ready `AppIcon.appiconset` and layered SVGs), menu-bar template icons, logotype and lockups.
- `design/daisyshot/tokens/DaisyshotTheme.swift` — starter token file.

Goal: re-skin the existing UI to match the spec. Keep all features, settings keys, defaults and behaviour unchanged except the additions listed in DESIGN_SPEC.md §8.

How to work:
1. Explore the project first: UI framework (SwiftUI/AppKit), where the status-item menu, Settings window and each pane live, how colours/assets are organised, and every occurrence of "Bestshot"/"bestshot". Then show me a short plan grouped into phases before editing.
2. Phase 1 — foundation: add the tokens (adapt DaisyshotTheme.swift to our conventions), import assets into the asset catalog (default app icon = `handles`; `crosshair` and `viewfinder` as alternate image assets; menu-bar icons with template rendering where the spec says so; logotype).
3. Phase 2 — status item + menu (DESIGN_SPEC §7), including the recording indicator (monochrome template vs yellow-centre non-template picked by appearance).
4. Phase 3 — Settings window shell: sidebar (tile colours + SF Symbols from §5, tinted selected row), cards, rows, and reusable controls (toggle tint, pop-up, buttons, segmented, slider, keycap, record-shortcut ghost button, chips). Build these as shared components, then apply them pane by pane: General (with the new Appearance card: app-icon picker that sets `NSApp.applicationIconImage` and persists the choice), Shortcuts, Quick Access Overlay, Wallpaper, Screenshots, Screen Recording, Annotate, Advanced, About.
5. Phase 4 — rename per §9. Add `daisyshot://` and keep `bestshot://` as an alias. Do NOT change the bundle identifier.
6. After each phase: build, fix warnings you introduced, and tell me what to look at. Check both light and dark mode. Commit per phase on a new branch `rebrand/daisyshot`.

Ask me before: changing any persisted settings key, the bundle ID, minimum macOS version, or adding a third-party dependency. If something in the mockup conflicts with native macOS behaviour, prefer the native control styled with our tokens and tell me.

Copy everything below the line into Claude Code, run from the root of the app's repository, after copying this folder to `design/record-setup/`.

---

Redesign the Record Screen setup overlay (the screen shown after "Record Screen": dimmed screen, source bar, selection frame, record controls). The rest of the Daisyshot rebrand is already done — reuse the existing Daisyshot colour tokens, components and assets; do not touch other screens.

Design hand-off in `design/record-setup/`:
- `RECORD_SETUP_SPEC.md` — read fully first. The "Final decisions" list overrides any older text inside the HTML mockups.
- `reference/html/RecPrep.dc.html` — the whole overlay as one component with every mode; exact colours, sizes, radii are inline. `Rec*Light/Dark.dc.html` show each situation; `RecParts.dc.html` all states; `RecSpec.dc.html` measurements and placement rules. Ignore the mockup tool's templating (`<x-dc>`, `<sc-for>`, `<sc-if>`, `<dc-import>`, `{{…}}`, the script block).

Key changes:
- Source bar (glass): Cancel · Screen / Window / Area / **Device** · Camera / Microphone (live level meter) / System audio · Settings.
- Remove the old record bar under the selection, and remove the GIF | Studio switch, cursor button and keystrokes button. Recording is always Studio; GIF is chosen at export; keystrokes are always captured.
- New centred **Start card** (name of the target + output size + big "Start Recording"): centre of each display (one card per display on multi-monitor setups), centre of the hovered window (app icon + window title), centre of the area (or beside it if the area is small), right of the iPhone/iPad preview.
- Selection frame with 8 petal-shaped handles, yellow centre dot, size label.
- Keyboard: Esc, Space (Window ⇄ Area), Return, ⌘1–4, arrow nudge.

How to work:
1. Explore first: where the current overlay lives, how capture/recording is wired (ScreenCaptureKit / AVFoundation), how GIF/Studio, cursor and keystroke options are currently stored and used. Show me a short plan before editing.
2. Phase A — overlay UI: source bar, selection frame, Start card and placement rules, multi-display cards, window-hover cards, keyboard. Keep the existing capture pipeline; just feed it the chosen target. Default the removed options (Studio on, keystrokes captured) without deleting their stored settings keys.
3. Phase B — Device source (iPhone/iPad): investigate and propose how to capture a connected device (wired first), then show me the approach before writing capture code. After I approve: picker menu, live preview, "iPhone audio" option, Start card to the right of the preview.
4. After each phase: build, fix warnings you introduced, check light and dark mode and a two-display setup if possible, and commit on a branch `feature/record-setup`.

Ask me before: changing persisted settings keys, entitlements or privacy usage strings, the minimum macOS version, or adding a dependency.

# HeroHelper - TBC Anniversary Edition - Changelog

## v1.0.0

First stable release. Everything below is net-new since the `v0.1.0`
pre-release block further down this file.

### New features

- **Hash-based import/export.** Per-boss settings now serialize to an opaque `HH!<base64>` "hash" that captures a *full* snapshot of every boss's effective config (not just overrides). Importing a hash reproduces the sender's setup exactly regardless of the receiver's database defaults. Still accepts the legacy `HH1|...` / `HH2|...` plaintext for backward compatibility. See [modules/Database.lua](modules/Database.lua).
- **`/hh mobtest [HP%]` command.** Command-line-only diagnostic that arms the reminder button for your current target and fires it when that mob drops below the configured HP threshold (default 50%). Captures target GUID at invocation time so it survives retargeting; auto-disables on fire, on target death, or after a 10-minute safety timeout. Useful for verifying the reminder pipeline on a training dummy without pulling a real raid boss. See [modules/Triggers.lua](modules/Triggers.lua).
- **Bosses tab "Reset" button.** Top-right of the Bosses config pane alongside Export / Import. Opens a confirmation popup; accepting clears every per-boss override and returns every boss to the researched database default.
- **Researched default BL/Hero timings.** Cross-checked every boss default against TBC Classic community guides (Icy Veins, Wowhead, r/classicwow BL-timing threads, Method, Warcraft Tavern). Four defaults changed to match consensus: Curator → `hp 20` (Evocation burn window), Morogrim → `hp 25` (after second murloc wave), Hex Lord Malacrass → `pull` (skip a Spirit Bolts cycle), Shade of Akama → `hp 35` (fire during real DPS phase). The other 46 bosses were already correct. See the inline comments in [modules/Database.lua](modules/Database.lua).
- **Sound dropdown replaced with inline selectable rows.** The Blizzard/LibUIDropDownMenu dropdown for sound selection had multiple issues (foreign LSM entries flooding the list, dropdown taller than the screen, click routing bugs). Replaced with a compact scrollable list of selectable rows inside the General tab.

### Bug fixes

- **Reminder button actually appears in combat.** Protected frames with `SecureActionButtonTemplate` cannot have Show/Hide/SetAlpha called in combat lockdown, and TBC Classic's layout engine mis-propagated container-relative anchors on a protected child when the non-protected parent was moved mid-combat (observed `h=132313` on a 52-tall button). Fixed by placing the non-protected container at the player's saved position at Initialize and never moving it again — visibility is toggled purely via `container:SetAlpha(0|1)`, which is always allowed, and the protected button uses a single `CENTER` anchor plus an explicit `SetSize` so it has deterministic dimensions.
- **BigWigs hook now installs cleanly.** `BigWigs:RegisterMessage(…)` was being called with method syntax, passing `BigWigs` itself as the subscriber; BigWigs rejected it with "attempted to register a function to BigWigsLoader, you might be using : instead of . to register the callback." Fixed by using dot syntax and passing the HeroHelper namespace as the subscriber, per CallbackHandler-1.0's convention.
- **Bosses tab populates on first open.** `BuildBossesTab` called `RefreshBossList` before `configState.frame` had been assigned, so the initial refresh silently no-opped and the boss list appeared empty until the player clicked the raid dropdown once. Fixed the init ordering in `Config:CreateFrame`.
- **Import / Export popup no longer vanishes on first click.** The popup's edit-box background was a bare `Texture`, but `AddThinBorder` calls `:CreateTexture` on its argument — a method only Frames have. The first click on Export or Import hit a silent error frame. Wrapped the background in a real `Frame` so the border helper works, enlarged the popup to 520×360 to fit the full-DB hash, and wrapped the button click handlers in `pcall` so future silent errors surface in chat.
- **Phase trigger option hidden for bosses without yells.** The `Phase` entry in the per-boss trigger-type dropdown silently did nothing on bosses whose database entry had no `yells = { … }` table, because the phase-detection engine matches boss-yell text. Only the ~13 bosses with yells (Prince, Vashj, Illidan, Kil'jaeden, etc.) now show the Phase option in their dropdown.

### Chores

- **Removed leftover `/hh debugsound` slash command.** Was added as temporary instrumentation while tracking down the sound-dropdown bug and said "will be stripped once the dropdown is confirmed working." The sound dropdown was since replaced with inline rows; the diagnostic is obsolete. This was also the only code path in the addon printing debug-style output unconditionally — the addon is now silent outside of user-initiated slash commands, actual errors, and `/hh debug`.
- **Sticky `/hh test` mode toggle.** Test mode is now a persistent toggle rather than a timed preview — drag the button into position, then run `/hh test` again (or the same keybind) to turn it off.

### Files

Net additions / significant rewrites since v0.1.0:
- `Libs/LibUIDropDownMenu/` (embedded to dodge the tainted Blizzard dropdown template in TBC Classic 2.5.5)
- Import / Export hash codec in `modules/Database.lua`
- `/hh mobtest` implementation in `modules/Triggers.lua`

---

## v0.1.0

Initial release.

### Features

- Boss database covering all nine TBC raids (Karazhan, Gruul's Lair, Magtheridon's Lair, Serpentshrine Cavern, Tempest Keep, Zul'Aman, Hyjal Summit, Black Temple, Sunwell Plateau) with sensible default trigger configs per boss.
- Per-boss, per-character trigger configuration: **Pull**, **HP %**, **Phase**, or **Off**.
- Phase detection via boss yells (phase-up events hard-coded per boss in [modules/Database.lua](modules/Database.lua)).
- Boss detection with three sources:
    - `BigWigs_OnBossEngage` callback when BigWigs is present
    - DBM `pull` callback when DBM is present
    - Fallback unit scan of target / focus / mouseover / boss1-5 / raid targets on target-change events
- HP poll ticker (250 ms) for HP %-type triggers; only runs on fights that actually use one.
- Reminder button as a `SecureActionButtonTemplate` with `type1=macro` / `macrotext1=/cast [@player] <spell>`. Uses the player's faction spell icon (Heroism for Alliance, Bloodlust for Horde). Hidden by default; shown only when all of the following are true:
    - The player is a Shaman who knows the spell
    - The spell is not on cooldown
    - Sated / Exhaustion is not on the player
    - The boss trigger condition evaluates positively
    - The reminder has not already fired for this pull
- Auto-hide triggers: combat end, successful cast (via cooldown detection), or debuff detection.
- Draggable, lockable reminder button. Size configurable 24–96 px (default 40).
- SharedMedia-3.0 sound selection with a small default set registered by the addon. Preview button in the config panel.
- Minimap button (self-contained, no LibDBIcon dependency) with left-click options / right-click lock toggle / drag to reposition.
- Two-tab config panel (General / Bosses) styled to match FishingKit's flat dark theme.
- Slash commands: `/hh`, `/hh lock`, `/hh unlock`, `/hh reset`, `/hh test`, `/hh debug`.
- Key bindings: `HEROHELPER_CONFIG`, `HEROHELPER_LOCK`, `HEROHELPER_TEST`.
- Per-boss settings **import / export** via a plain-text `HH1|...` share string. Copy-paste in chat to share tuned trigger configs with raid members. Import silently skips unknown boss IDs.
- Config panel closes with **ESC** (via `UISpecialFrames`).
- MIT license. CurseForge `.pkgmeta` in repo root.

### Fixes during initial development

- Test button no longer casts Heroism/Bloodlust. The secure macrotext is only armed when the reminder button is locked AND not in test mode; otherwise clicks and drags are no-ops. Fresh installs default to locked so the button works out of the box.
- Pulse glow is perfectly centered at every button size. Previously it animated via scale on a CENTER-anchored fixed-size texture, which drifted at larger sizes. Now animates alpha only on a texture anchored with symmetric SetPoint offsets recomputed in `ApplySize`.
- Button size slider's fill bar now renders correctly for the default 40 px value. Fill width is recomputed via `OnSizeChanged` instead of being baked in at construction time.

### Files

- `HeroHelper.toc`, `Core.lua`, `Bindings.xml`
- `modules/Database.lua`, `modules/Detection.lua`, `modules/Triggers.lua`
- `modules/ReminderButton.lua`, `modules/Minimap.lua`, `modules/Config.lua`
- `Libs/LibStub/`, `Libs/CallbackHandler-1.0/`, `Libs/LibSharedMedia-3.0/`
- `README.md`, `CHANGELOG.md`, `CLAUDE.md`, `LICENSE`, `.pkgmeta`, `.gitignore`

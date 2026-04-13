# HeroHelper - TBC Anniversary Edition - Changelog

## v1.2.1

### Changed

- Boss lists in the config panel are now sorted in **kill order**
  (matching AtlasLoot encounter order) instead of alphabetically.
  Affects Zul'Aman (Akil'zon before Nalorakk) and Black Temple
  (Bloodboil → RoS → Teron Gorefiend) most notably.

### Fixed

- Botanica default skip trigger moved from Thorngrin the Tender to
  Laj (Laj is the throwaway boss you skip Hero on, not Thorngrin).

## v1.2.0

### New

- **"Skip" trigger type** — per-boss option to intentionally suppress
  the reminder while keeping detection active. Useful for dungeon
  bosses where you want to save Hero/BL for a later boss (e.g.
  Thorngrin the Tender in Botanica, which now defaults to Skip).
  Available in the config dropdown and supported by export/import.

### Fixed

- Dungeon bosses no longer false-trigger when pulling trash nearby.
  The unit-scan fallback now requires `UnitAffectingCombat` for
  dungeon bosses before locking in a detection.
- Added an in-combat rescan ticker (0.5s) that covers chained pulls
  where the player engages a boss without leaving combat from prior
  trash. Self-cancels once a boss is found or combat ends.

## v1.1.2

### Fixed

- Non-shaman players with HeroHelper installed no longer join the
  coordination roster. Previously a non-shaman could win the election
  and suppress the real shaman's reminder entirely.
- The ReminderButton frame is no longer created for non-shaman classes,
  removing the invisible but mouse-interactive area that remained on
  screen.

## v1.1.1

### Fixed

- Removed `Bindings.xml` from the TOC file list — WoW auto-loads this
  file for key bindings; listing it in the TOC caused the regular XML
  parser to reject the `<Bindings>` schema, producing 7 XML warnings
  on every load.

### Internal

- Extracted `Detection:GetScanUnits()` to eliminate three copies of
  the unit-list builder (in `ScanUnits`, `GetCurrentBossHPPct`, and
  `Triggers:FindUnitByGUID`).

## v1.1.0

Major feature release: full TBC dungeon coverage, multi-shaman
coordination with role-based election, three new trigger types,
zone-aware boss lookup, and a project icon + screenshots in `media/`.

### New trigger types

- **Time after pull** (`type = "time", seconds = N`). Fires the reminder
  N seconds after combat starts. Useful for fights with a known sweet
  spot a fixed delay into the engagement (1–600 seconds, configurable
  per boss in the Bosses tab).
- **Compound (any-of)** (`type = "any", conditions = {...}`). Fires on
  the FIRST of multiple conditions. Pair a `phase` with an `hp` and a
  `time` safety net so you never miss a burn window when yell-based
  phase detection is unreliable. Configure via the new "Multi" option
  in the per-boss type dropdown — opens a small popup with checkbox +
  value editors for each sub-condition. Compound configs serialize
  through the export/import hash as `any(pull;hp:25;time:60)`.

### 5-man dungeon support

- 50 TBC dungeon bosses across 15 dungeons added to the database. All
  flagged `isDungeon = true` and gated behind a new General-tab toggle
  (**"Alert for dungeon bosses (5-man, on pull)"**, off by default so
  raid-only installs don't suddenly start beeping on Hellfire trash).
- Researched non-pull defaults: Grand Warlock Nethekurse `hp 20`,
  Talon King Ikiss `hp 25`, Murmur `hp 40`, Pathaleon `hp 20`, and
  Harbinger Skyriss `phase 2` with verified yells. The other 45
  dungeon bosses default to `pull` — correct for short heroic 5-mans.

### Zone-aware boss lookup

- Magisters' Terrace's Kael'thas Sunstrider was previously omitted
  because his name collided with Tempest Keep's Kael'thas. The
  database name index now supports multi-match entries with explicit
  `zone` tags, and `DB:LookupByName` takes an optional zone string
  that disambiguates via `GetRealZoneText()`. Both Kael'thas entries
  now exist in the database and detect correctly inside their
  respective instances.

### Multi-shaman coordination

- New `modules/Comms.lua` adds an addon-message protocol so multiple
  HeroHelper-using shamans in the same group don't double-Heroism.
  Roster-based election: each user broadcasts a `HELLO:<priority>`
  on join, the lowest-priority alive shaman is elected, and ONLY
  that one client's HeroHelper produces reminders. Everyone else is
  completely silent (no popup, no sound).
- Players pick a **role** in the General tab: *Primary*, *Secondary*,
  *Backup*, or *Auto*. Lower priority wins. Auto falls back to
  alphabetical name precedence.
- The election **locks** when the group reaches its instance's
  expected size (5 for 5-mans, 10 for Karazhan / Zul'Aman, 25 for
  the larger raids — sourced from `GetInstanceInfo`). The locked
  roster is a snapshot — late joiners after lock are not added, the
  order is fixed for the duration of the run.
- If the elected winner dies during a fight, the next-priority alive
  shaman in the locked roster silently takes over (no chat noise).
- Optional **raid-chat announcement** (off by default): on lock, the
  elected winner posts a one-line "HeroHelper: <name> will Heroism.
  Order: a > b > c" to RAID/PARTY chat. Posted exactly once per group
  formation, naturally deduplicated because every client computes
  the same winner.
- New diagnostic command **`/hh roster`** dumps the current (live or
  locked) roster, each member's role, and the active winner.

### New diagnostic command

- **`/hh mobtest pull`** arms a one-shot listener that fires the
  reminder on the next combat start, against any target. Lets you
  verify the pull-trigger pipeline against a target dummy without
  needing an actual boss. The HP-mode `/hh mobtest [%]` from v1.0.0
  remains.

### UI improvements

- Bosses tab gains a **Reset** button alongside Export / Import that
  wipes every per-boss override and returns every boss to the
  database default. StaticPopup confirmation prevents accidents.
- Per-boss row's value editor now shows a unit suffix (`%`, `s`)
  matching the current trigger type so the meaning of the number
  is unambiguous.
- The "Phase" trigger option is hidden from the per-boss dropdown
  for bosses without yell patterns in the database, instead of
  letting the player pick a trigger that would silently never fire.
- Brighter, wider, faster reminder-button glow tuning so the popup
  is harder to miss in a busy raid UI.

### Bug fixes

- **Reminder button actually appears in combat now.** A TBC layout
  bug propagated stale heights through `SetAllPoints` on a protected
  child whose container moved mid-combat (we observed h=132313 on a
  52-tall button). Fixed by parking the container at the player's
  saved position permanently and toggling visibility purely via
  `SetAlpha`. The container never moves at runtime.
- **Pull triggers re-evaluate on `COMBAT_START`.** Previously, if the
  player tab-targeted a boss before the tank pulled, `BOSS_PULL`
  fired pre-combat, `IsReady` bailed on the inCombat gate, and the
  trigger silently missed (the boss was already locked in by
  Detection so it never re-fired). Triggers now also runs the
  evaluator on `COMBAT_START`, with the same triggered-latch making
  it idempotent.
- **Bosses tab populates on first open** instead of requiring a
  raid-dropdown click to refresh. Init ordering bug in `Config:CreateFrame`.
- **Compound popup checkboxes now toggle on click.** `MakeCheckbox`
  only installs its OnClick handler when you call `:HookClick(fn)`,
  which the popup wasn't doing.
- **Compound popup value editors no longer overflow the popup frame.**
  Previously anchored to the right edge of the 260 px-wide checkbox
  container; now anchored to the popup's right edge directly.
- **Import / Export popup no longer crashes on first click.** A bare
  Texture was being passed to `AddThinBorder` which calls
  `:CreateTexture` on its argument — a method only Frames have.
- **BigWigs hook now installs cleanly.** `RegisterMessage` is a
  CallbackHandler-1.0 method that takes a subscriber as the first
  argument, not `self`; we now use dot syntax with the HeroHelper
  namespace.

### Documentation & assets

- README rewritten as a player-facing overview with screenshot
  placeholders, and the `media/` folder is now in the repo:
  - `media/icon.png` — addon logo
  - `media/screenshots/screenshot-reminder.png`
  - `media/screenshots/screenshot-options-general.png`
  - `media/screenshots/screenshot-options-bosses.png`
- CLAUDE.md updated with `modules/Comms.lua`, the `CHAT_MSG_ADDON` and
  `GROUP_ROSTER_UPDATE` events, and the v1.1.0 version pin.

### Removed

- Legacy `/hh debugsound` slash command (leftover instrumentation
  from the v1.0.0 sound-dropdown work).

---

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

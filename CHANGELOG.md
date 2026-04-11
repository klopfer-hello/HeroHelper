# HeroHelper - TBC Anniversary Edition - Changelog

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
- MIT license. CurseForge `.pkgmeta` in repo root.

### Files

- `HeroHelper.toc`, `Core.lua`, `Bindings.xml`
- `modules/Database.lua`, `modules/Detection.lua`, `modules/Triggers.lua`
- `modules/ReminderButton.lua`, `modules/Minimap.lua`, `modules/Config.lua`
- `Libs/LibStub/`, `Libs/CallbackHandler-1.0/`, `Libs/LibSharedMedia-3.0/`
- `README.md`, `CHANGELOG.md`, `CLAUDE.md`, `LICENSE`, `.pkgmeta`, `.gitignore`

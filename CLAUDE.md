# HeroHelper - CLAUDE.md

## Project Overview

HeroHelper is a World of Warcraft addon for **TBC Classic Anniversary** (interface version 20505, game version 2.5.5). It reminds Shamans to cast Heroism / Bloodlust at the right moment on every raid boss by showing a moveable, non-protected visual reminder frame only when the configured trigger condition for the current boss evaluates to true. The actual cast is performed by the user via a keybind they set on the per-character `HeroHelperCast` macro (Escape → Key Bindings → Macros).

The addon uses a global namespace `HH` (also `HeroHelper`) populated via the addon vararg `local ADDON_NAME, HH = ...`.

The architecture is deliberately aligned with the [FishingKit](https://github.com/Klopfer-Hello/FishingKit) addon — same `Core.lua` + `modules/` split, same flat dark config styling, same self-contained minimap button pattern, same SemVer release process. See that project for reference when touching shared conventions.

## File Structure

| File | Purpose |
|---|---|
| [Core.lua](Core.lua) | Addon framework: event dispatch, state machine, saved-variable defaults, slash commands, event bus (`HH.Events`) |
| [Bindings.xml](Bindings.xml) | Key binding declarations |
| [modules/Database.lua](modules/Database.lua) | Static raid-boss database with per-boss default triggers (pull / hp / phase) and phase-up yell patterns |
| [modules/Detection.lua](modules/Detection.lua) | Boss identification via BigWigs callback, DBM callback, or unit-scan fallback |
| [modules/Triggers.lua](modules/Triggers.lua) | Trigger evaluation engine. Listens for BOSS_PULL, BOSS_YELL, COMBAT_END, COMBAT_START. Fires `HEROHELPER_TRIGGER` when conditions are met. Also owns the `/hh mobtest` diagnostic mode and the per-pull / time / hp / phase / compound (`any`) condition arming |
| [modules/Comms.lua](modules/Comms.lua) | Manual multi-shaman coordination over the addon-message channel. HELLO-discovered live roster, plus an explicit `/hh roster lock` command that snapshots the roster, announces the resolved hero order to chat, and suppresses non-winners for the rest of the run. Alive-aware fallback (Primary > Secondary > Backup) is re-evaluated on every fire. Without an active lock, every HeroHelper-using shaman fires independently — there is no auto-locking. |
| [modules/ReminderButton.lua](modules/ReminderButton.lua) | The moveable non-protected visual reminder frame (icon + pulse + border + label). Also owns the persistent `HeroHelperCast` macro (see EnsureMacro). No cast machinery — casts happen via the user's keybind on the macro. |
| [modules/Minimap.lua](modules/Minimap.lua) | Self-contained minimap button (same pattern as FishingKit, no LibDBIcon) |
| [modules/Config.lua](modules/Config.lua) | Two-tab (General / Bosses) config panel |
| [Libs/](Libs/) | Embedded libraries: `LibStub`, `CallbackHandler-1.0`, `LibSharedMedia-3.0`. LSM provides the shared sound registry that ShamanPower and others use, so HeroHelper's sound picker sees every key any addon registers. `LibUIDropDownMenu-4.0` was removed after stale-button cross-contamination issues on its shared global list frame; dropdowns are now a self-contained custom widget in Config.lua with per-popup state and click-outside dismissal. |

## Event Bus (HH.Events)

Modules do not register their own Blizzard event frames. Instead `Core.lua` owns one shared event frame that re-fans events into the internal event bus via `HH.Events:Fire(name, ...)`. Modules subscribe in their `Initialize()` method via `HH.Events:On(name, fn)`.

Internal events:

| Event | Fired from | Payload |
|---|---|---|
| `PLAYER_LOGIN` | Core | - |
| `PLAYER_ENTERING_WORLD` | Core | `...isInitialLogin, isReloadingUi` |
| `COMBAT_START` | Core (`PLAYER_REGEN_DISABLED`) | - |
| `COMBAT_END` | Core (`PLAYER_REGEN_ENABLED`) | - |
| `TARGET_CHANGED` | Core (`PLAYER_TARGET_CHANGED`) | - |
| `MOUSEOVER_CHANGED` | Core (`UPDATE_MOUSEOVER_UNIT`) | - |
| `CLEU` | Core (`COMBAT_LOG_EVENT_UNFILTERED`) | `CombatLogGetCurrentEventInfo()` values |
| `COOLDOWN_CHANGED` | Core (`SPELL_UPDATE_COOLDOWN`) | - |
| `PLAYER_AURA_CHANGED` | Core (`UNIT_AURA` for player) | - |
| `CHAT_MSG_ADDON` | Core (`CHAT_MSG_ADDON`) | `prefix, message, channel, sender, ...` |
| `GROUP_ROSTER_UPDATE` | Core (`GROUP_ROSTER_UPDATE`) | - |
| `BOSS_PULL` | Detection | `bossID, unit` |
| `HEROHELPER_TRIGGER` | Triggers | `bossID, reason` |

## State (HH.State)

```
HH.State = {
    isShaman        -- player class == SHAMAN
    spellID         -- 2825 or 32182 depending on faction
    spellName       -- GetSpellInfo(spellID)
    buffSpellName   -- localized Sated or Exhaustion name

    inCombat        -- true between PLAYER_REGEN_DISABLED and _ENABLED
    currentBossID   -- Database key of the current boss (nil if none)
    currentBossName -- display name
    pullTime        -- GetTime() when pull was detected

    triggered       -- latches true once HEROHELPER_TRIGGER has fired this pull
    lastHPCheck
}
```

## Trigger Logic

1. `PLAYER_REGEN_DISABLED` fires → `Detection:ScanUnits()` runs.
2. If Detection matches a boss name against the database, it sets `currentBossID` and fires `BOSS_PULL`.
3. Triggers module reads the per-boss config via `Database:GetTriggerConfig(bossID)`:
    - `type == "pull"`  → fire immediately
    - `type == "hp"`    → start a 250 ms poll ticker until HP% ≤ threshold
    - `type == "time"`  → schedule a one-shot timer for `seconds` after pull
    - `type == "any"`   → compound; arm each sub-condition in parallel and fire on the first to satisfy
    - `type == "skip"`  → never fire for this boss
4. Before firing, Triggers checks:
    - addon enabled
    - player is shaman
    - BL/Hero not on cooldown (`GetSpellCooldown`)
    - Sated/Exhaustion not on player
    - `triggered` is false
5. `HEROHELPER_TRIGGER` → ReminderButton shows the non-protected visual reminder, plays sound, pulses.
6. The user presses the key they've bound to the `HeroHelperCast` macro → WoW casts BL/Hero via the native macro keybind path. No click-to-cast on the reminder — the reminder never captures mouse events that would fire a spell.
7. On `COMBAT_END` the whole state resets. `PLAYER_AURA_CHANGED` (Sated/Exhaustion) and `COOLDOWN_CHANGED` trigger an early auto-hide of the reminder so it doesn't linger after the cast.

## Detection Sources

- **BigWigs**: `BigWigs:RegisterMessage("BigWigs_OnBossEngage", handler)` — the engaged module's `displayName` is matched against `Database:LookupByName`.
- **DBM**: `DBM:RegisterCallback("pull", handler)` — the mod's `combatInfo.name` or `id` is matched.
- **Unit scan fallback**: on `TARGET_CHANGED`, `MOUSEOVER_CHANGED`, or `COMBAT_START`, iterate `target`, `focus`, `mouseover`, `boss1..5`, `party*target`, `raid*target` and match each `UnitName()` against the database name index.

Whichever source fires first locks in `currentBossID` until `COMBAT_END` clears it. Re-identification mid-fight is a no-op (Detection guards with `if currentBossID then return end`).

## TBC Classic 2.5.5 API Notes

- `ENCOUNTER_START` / `ENCOUNTER_END` do not exist. We use `PLAYER_REGEN_DISABLED` + unit scanning + boss mod callbacks instead.
- `boss1`..`boss5` unit tokens exist in TBC Anniversary but are not always populated — boss mods fill them in reliably, so we scan them anyway.
- `UnitDebuff("player", i)` still returns the multi-value legacy format (name first). We only need the name.
- `GetSpellCooldown(name_or_id)` returns `start, duration, enabled`. A `duration > 1.5` indicates non-GCD cooldown.
- **Protected-frame visibility during combat is not solvable via the usual tools on TBC 2.5.5.** We tried `SetHitRectInsets`, `SecureHandlerBaseTemplate.Execute`, `SecureHandlerStateTemplate` + `_onstate-display` snippet, and `RegisterStateDriver(frame, "visibility", …)` — all of them silently no-op when invoked from a mid-combat callsite (HP poll ticker, cooldown timer). Only operations that fire during the `PLAYER_REGEN_DISABLED` event dispatch window (e.g. pull-triggered Show) actually took effect. The `LibActionButton-1.0-ElvUI` fork we tried to embed also depends on retail-only C_* tables (`C_UnitAuras`, `C_ActionBar.EnableActionRangeCheck`, etc.) that don't exist in 2.5.5.

  The workaround is the one every combat-reminder addon for Classic uses: **decouple visual from cast.** The reminder is a plain non-protected `Frame` (trivial `Show()`/`Hide()` in any state); the cast is delegated to a persistent per-character macro (`HeroHelperCast`) the user binds a key to in Escape → Key Bindings → Macros. WoW's native keybind → macro system handles the combat-safe cast.
- Persistent macros are created with `CreateMacro(name, icon, body, 1)` (the `1` flags it per-character) and refreshed with `EditMacro(index, ...)`. Both calls are combat-restricted; we gate them on `InCombatLockdown()` and refresh on PLAYER_LOGIN / PLAYER_ENTERING_WORLD. `GetMacroIndexByName` returns the slot for idempotent updates.
- `UIDropDownMenuTemplate` requires a globally unique frame name per instantiation — we generate them via a monotonic counter.
- Native `Slider` is not reliably draggable in TBC Anniversary (same issue FishingKit hit); we use a manual hit-area Frame with `OnMouseDown` cursor tracking.
- `PlaySoundFile(file, "Master")` works for custom sounds via file path. For built-in sounds we use numeric IDs via `PlaySound()`.
- Checkbox: rather than depend on a Blizzard template (whose names vary), we hand-roll a 14×14 flat checkbox matching FishingKit's style.

## Versioning

Follows **Semantic Versioning** (`MAJOR.MINOR.PATCH`):

| Change type | Bump | Example |
|---|---|---|
| Breaking (SavedVariables schema incompatible, removed features) | MAJOR | 1.x.x → 2.0.0 |
| New backwards-compatible features | MINOR | 1.0.x → 1.1.0 |
| Bug fixes only | PATCH | 1.1.x → 1.1.1 |

Current version: `1.3.0` (locale-independent NPC ID detection, multi-string yell patterns, German deDE support, DBM callback fix, kill-order boss lists, skip trigger type, dungeon false-trigger fix, in-combat rescan ticker, multi-shaman coordination, dungeon support, compound triggers, time triggers). Semver applies going forward.

### Release Process

On each release update all four in one commit, then tag:

1. `CLAUDE.md` — bump the File Structure / API Notes / Triggers sections if changed
2. `CHANGELOG.md` — add a new `## vX.Y.Z` section at the top
3. `README.md` — update the version in Compatibility
4. `HeroHelper.toc` — bump `## Version:`

```
git add CLAUDE.md CHANGELOG.md README.md HeroHelper.toc
git commit -m "chore: release vX.Y.Z"
git tag -a vX.Y.Z -m "vX.Y.Z"
```

## Coding Conventions

- Module pattern: `HH.ModuleName = {}; local M = HH.ModuleName`
- Each module exposes an `:Initialize()` called from Core
- Event subscriptions use `HH.Events:On(name, fn)`, never `frame:RegisterEvent`
- Settings access: `HH.db.settings.enabled` (account-wide) / `HH.chardb.settings.*` (per-character)
- Per-boss config overrides: `HH.chardb.bosses[bossID] = { type = ..., hp = ..., phase = ..., enabled = ... }`
- Debug logging: `HH:Debug("message")` (gated by `HH.db.settings.debug`)

# HeroHelper

A TBC Classic Anniversary addon that reminds Shamans to cast **Heroism** / **Bloodlust** at the right moment on every raid boss.

## What it does

HeroHelper hides a big moveable button off-screen by default. When you pull a raid boss HeroHelper knows about, it evaluates a per-boss trigger rule (pull / HP% / phase) and pops the button up with a glow and an optional sound. You click it to cast Heroism or Bloodlust at yourself — the button uses `SecureActionButtonTemplate` so the click is a real spell cast, not a chat message. The button then fades out as soon as the cast lands or combat ends.

## Features

- Covers every boss in all nine TBC raids (Karazhan → Sunwell Plateau) with sensible default triggers
- Per-boss, per-character configuration: **Pull**, **HP %**, **Phase**, or **Off**
- Phase detection via boss yells (phase-up events hard-coded per boss)
- Detection hooks into **BigWigs** and **DBM** when present; falls back to scanning target / mouseover / focus / raid targets for a name match
- Suppresses the reminder while Sated (Alliance) or Exhaustion (Horde) is on the player, or while BL/Hero is still on cooldown for you — so a second shaman can't double-trigger it
- Movable reminder button, lockable in place, configurable size (default 40×40)
- SharedMedia sound library for the cue
- Minimap button (left-click options, right-click toggles the lock, drag to move)
- **Import / export** of per-boss settings as a plain-text share string, so raid members can sync their Heroism/BL triggers
- MIT licensed, packaged for CurseForge via `.pkgmeta`

## Slash Commands

| Command | Description |
|---|---|
| `/hh` | Open the options panel |
| `/hh lock` / `/hh unlock` | Lock or unlock the reminder button |
| `/hh reset` | Reset the reminder button's screen position |
| `/hh test` | Show a test reminder (outside combat) |
| `/hh debug` | Toggle debug output |

## Compatibility

- **Game version**: TBC Classic Anniversary (2.5.5)
- **Interface version**: 20505
- **Addon version**: 0.1.0
- **Dependencies**: none required. Integrates with **BigWigs** and **DBM** if either is installed. LibSharedMedia-3.0 is embedded.

## Installation

1. Download the latest release from CurseForge (or clone the repo into `Interface/AddOns/HeroHelper`).
2. Launch WoW. Type `/hh` to open the options.
3. In the **Bosses** tab, review the default triggers per raid and tweak them to your raid's strategy.
4. The reminder button is invisible until it's time to cast — drag the placeholder during `/hh test` to position it, then lock it in place.

## Acknowledgments

Architecture and code style are aligned with [FishingKit](https://github.com/Klopfer-Hello/FishingKit) by For Fun Studios / Klopfer-Hello. Embedded libraries (`LibStub`, `CallbackHandler-1.0`, `LibSharedMedia-3.0`) are sourced from the BigWigs distribution.

## License

MIT — see [LICENSE](LICENSE).

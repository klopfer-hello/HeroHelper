<img src="media/icon.png" alt="HeroHelper" width="96" align="left"/>

## HeroHelper

A simple TBC Classic Anniversary addon that tells Shamans **when** to cast Heroism / Bloodlust on every raid and dungeon boss.

<br clear="left"/>

No more checking the spreadsheet between pulls. No more "wait, was I supposed to lust this one?". A glowing button pops up at the right moment — you click it, you cast, you keep DPS'ing.

![Reminder button on a boss pull](media/screenshots/screenshot-reminder.png)
*The reminder button appears when it's time to cast. Click it to fire Heroism or Bloodlust.*

---

### What it does

- Watches every raid pull and every dungeon boss.
- Pops a glowing, clickable button at the moment your raid wants Heroism — on the pull, at a specific HP%, when a phase starts, after a set time, or any combination.
- Stays out of your way the rest of the time. Hidden until needed, fades out after the cast.
- Knows about every boss in **all nine TBC raids** and **every TBC 5-man dungeon**, with researched defaults out of the box.
- Coordinates with **other shamans in your group** so two of you don't waste a Heroism on the same pull.

---

### How to use it

**1. Install.** Drop the `HeroHelper` folder into `Interface/AddOns/`, or grab the latest release from CurseForge.

**2. First-time setup.** Type `/hh` to open the options.

![Options panel](media/screenshots/screenshot-options-general.png)

- In the **General** tab, choose your sound and (if you raid with another shaman) pick your role: *Primary*, *Secondary*, *Backup*, or *Auto*.
- Type `/hh test` once to position the reminder button on screen, drag it where you want it, then `/hh test` again to lock it in.

**3. Pick your triggers.** Open the **Bosses** tab.

![Bosses configuration](media/screenshots/screenshot-options-bosses.png)

Each boss has a default trigger that should be sensible for most raids. You can change any of them:

- **Pull** — fires the reminder the moment you engage the boss.
- **HP %** — fires when the boss drops below a chosen HP percentage (good for execute phases).
- **Phase** — fires when the boss enters a specific phase (only for bosses with detectable phase yells).
- **Time** — fires a fixed number of seconds after the pull.
- **Multi** — fires on the *first* of multiple conditions you pick (e.g. *phase 3 or HP 25% or 90 seconds in*).
- **Off** — disable the reminder for this boss entirely.

Click **Export** to copy your settings as a share string and send them to the rest of your raid. They click **Import** and you're synced.

**4. Pull a boss.** When it's time, the button pops up. Click it. Done.

---

### Coordinating with other shamans

If your raid has more than one shaman with HeroHelper, set your **role** in the General tab:

- **Primary** — you're the designated Heroist; the button always pops for you first.
- **Secondary** — the button only pops if the Primary is dead.
- **Backup** — fires if both Primary and Secondary are dead.
- **Auto** — no explicit role; HeroHelper picks one shaman per pull automatically.

The other shamans see *"Heroism deferred to <name>"* in chat when their reminder is suppressed. If your Primary dies before the pull resolves, the Secondary's button pops automatically.

---

### Slash commands

| Command | What it does |
|---|---|
| `/hh` | Open the options panel |
| `/hh test` | Show / hide the reminder button so you can drag it into position |
| `/hh mobtest` | Test the reminder by targeting any mob (fires when it drops below 50% HP) |
| `/hh mobtest pull` | Test the pull-trigger flow on the next mob you engage |
| `/hh lock` / `/hh unlock` | Lock or unlock the reminder button in place |
| `/hh reset` | Move the reminder button back to screen center |
| `/hh debug` | Toggle verbose chat output (for troubleshooting) |

---

### Compatibility

- **Game version**: TBC Classic Anniversary (2.5.5)
- **Addon version**: 1.1.0
- Works on its own. Plays nicely with **BigWigs** and **DBM** if you have them.

---

### Acknowledgments

Architecture and visual style are aligned with [FishingKit](https://github.com/klopfer-hello/fishingkit-reworked) — same module layout, same flat dark config theme, same self-contained minimap button pattern.

---

### License

MIT — see [LICENSE](LICENSE).

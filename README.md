# HealOnRaid

A small WoW Classic Era ("Classic Forever") addon that shows **your** healing done
as floating numbers on the raid and party frames.

## Install

Copy the `HealOnRaid` folder into:

```
World of Warcraft/_classic_era_/Interface/AddOns/HealOnRaid/
```

so that `Interface/AddOns/HealOnRaid/HealOnRaid.toc` exists, then reload the game
(or `/reload` if you were already logged in).

## How it detects heals (important)

On this client (1.60.x, "Classic Forever") **the combat log is off limits to
addons**: calling `RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")` throws
`ADDON_ACTION_FORBIDDEN` and taints the addon for the rest of the session.
This was confirmed independently by another addon author on build
1.60.1.69913 (BiSHealing PR #23). There is no way around it from Lua.

So HealOnRaid infers heals instead:

1. `UNIT_SPELLCAST_SENT` records who each of your casts is aimed at.
2. `UNIT_SPELLCAST_SUCCEEDED` says the cast landed.
3. The target's health is then sampled for ~0.7s, and the rise is shown.

**What this costs, compared to a combat-log addon:**

| | Status |
| --- | --- |
| Direct heal amounts | works |
| Overhealing | **not possible** — a health delta can't see wasted healing |
| HoT ticks | **not possible** — ticks have no cast event |
| Crit indication | **not possible** |
| Accuracy | approximate; damage landing in the same instant understates the heal |

If Blizzard ever reopens the combat log on this client, all four become easy
to restore — the display layer already accepts overheal and crit arguments.

## What it does

- Finds the raid/party frame currently showing the healed unit and floats a
  green `+amount` upward from it, fading out over ~1.5s.
- Heals landing on the same person within 0.25s are merged into one number, so a
  Chain Heal bounce or a wave of HoT ticks doesn't spam the frame.
- Crits are shown larger.

Supported frames out of the box: Blizzard compact raid frames, the party frames,
and the player/target/focus frames. Other frame addons can register themselves:

```lua
HealOnRaid:RegisterFrame(myFrame)   -- frame must have .unit or .displayedUnit
```

## Commands

| Command | Effect |
| --- | --- |
| `/hor` | show the command list and current settings |
| `/hor on` / `/hor off` | toggle the display |
| `/hor overheal` | explains why overheal is unavailable on this client |
| `/hor size <n>` | font size |
| `/hor min <n>` | hide heals smaller than `n` |
| `/hor test` | float a test heal on your own frame |

## Settings

All options live in the `HealOnRaidDB` saved variable and can be edited directly
(colors, `duration`, `rise`, `mergeWindow`, `xOffset`/`yOffset`) if you want to
tune something the slash commands don't cover.

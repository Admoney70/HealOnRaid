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

## What it does

- Watches the combat log for your `SPELL_HEAL` and `SPELL_PERIODIC_HEAL` events.
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
| `/hor overheal` | toggle overheal numbers (off by default) |
| `/hor hots` | toggle HoT tick numbers |
| `/hor size <n>` | font size |
| `/hor min <n>` | hide heals smaller than `n` |
| `/hor test` | float a test heal on your own frame |

## Overhealing

Overheal tracking is already wired up but **off by default**, as agreed — confirm
the basic display works in a real raid first, then turn it on with
`/hor overheal`. With it on, each number gains a grey `(amount)` suffix showing
the wasted portion, and fully-overhealed heals are displayed instead of skipped.

## Settings

All options live in the `HealOnRaidDB` saved variable and can be edited directly
(colors, `duration`, `rise`, `mergeWindow`, `xOffset`/`yOffset`) if you want to
tune something the slash commands don't cover.

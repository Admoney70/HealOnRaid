# HealOnRaid

A small WoW Classic Forever (1.60.x) addon that shows where **your** healing is
landing, on the raid and party frames.

The client forbids addons from reading healing amounts — see below — so this
shows the spell name on the person you healed, not a number.

## Install

Copy the `HealOnRaid` folder into:

```
World of Warcraft/_classic_era_/Interface/AddOns/HealOnRaid/
```

so that `Interface/AddOns/HealOnRaid/HealOnRaid.toc` exists, then reload the game
(or `/reload` if you were already logged in).

## Why there are no numbers on this client

Two separate restrictions in the 1.60.x client make healing **amounts**
unobtainable by any addon:

1. **The combat log is closed.** `RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")`
   is a protected call: it throws `ADDON_ACTION_FORBIDDEN` and taints the addon
   for the rest of the session. Confirmed independently on build 1.60.1.69913
   (BiSHealing PR #23).
2. **Health is a "secret value".** `UnitHealth()` returns a value addons may
   store and pass along, but may not do arithmetic on, compare, or run
   `tostring()`/`format()` on. So a health delta cannot stand in for the amount,
   and even a secret amount could not be turned into text to draw. Grid2 hits
   the same wall.

This is a deliberate client-wide system, not something an addon can work
around. Amounts are not coming back unless Blizzard reopens one of the two.

## What it does instead: direct casts, with an estimate

Cast events are *not* secret, so the addon uses the one avenue left:

1. `UNIT_SPELLCAST_SENT` records who each of your casts is aimed at.
2. `UNIT_SPELLCAST_SUCCEEDED` says it landed.
3. The **spell name** floats up from that person's raid frame, prefixed with the
   heal figure from that rank's own tooltip where it can be read.

Only **direct, hard-cast heals** are tracked. HoTs, channels and totems have no
per-tick cast event, so nothing could be shown for them anyway, and their
tooltip figure covers the whole duration rather than one cast.

### About the estimate

A Classic spell tooltip states what the spell heals for *including your +healing
gear*, and it is static spell data rather than unit state, so it is not expected
to be secret the way `UnitHealth` is. If this client does make it secret, or the
wording does not parse, the addon silently falls back to the spell name alone —
it never errors. Run `/hor diag <spellID>` to see which applies to you.

**It is an estimate of the cast, not healing done.** It cannot know whether the
heal crit, and it cannot know how much was wasted as overheal. Treat it as "I
threw roughly this much at them", never as a measure of output.

| | Status |
| --- | --- |
| Which spell, on which target | works |
| Estimated heal from the tooltip | works if tooltips are readable here (`/hor diag`) |
| Actual healing done | **impossible** (secret values) |
| Overhealing, HoT ticks, crits | **impossible** (combat log) |

Because no API says which spells heal, matching is by name against a built-in
Classic list of direct heals (Priest/Druid/Paladin/Shaman). Those names are
English; on another locale, or for anything missing, use `/hor add <spell>`.

## Commands

| Command | Effect |
| --- | --- |
| `/hor` | show the command list and current settings |
| `/hor on` / `/hor off` | toggle the display |
| `/hor amounts` | explains why no numbers are shown on this client |
| `/hor estimate` | toggle the tooltip figure |
| `/hor diag <spellID>` | test whether tooltip figures are readable on your client |
| `/hor self` | toggle heals you cast on yourself |
| `/hor add <spell>` | treat another spell as a heal |
| `/hor size <n>` | font size |
| `/hor test` | float a test heal on your own frame |

## Settings

All options live in the `HealOnRaidDB` saved variable and can be edited directly
(colors, `duration`, `rise`, `mergeWindow`, `xOffset`/`yOffset`) if you want to
tune something the slash commands don't cover.

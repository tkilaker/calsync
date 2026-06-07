# calsync

Mirror busy time between macOS calendars as anonymous blocker events, so every calendar shows your true availability.

## Why

If you work across multiple organizations (consultant with several clients, two jobs, your own company), each org's scheduling assistant only sees its own tenant's free/busy. Colleagues book right over your other commitments. Cloud sync services (CalendarBridge, OneCal, Reclaim) solve this *if* every tenant lets you grant OAuth access to a third party — locked-down corporate tenants often don't.

calsync takes a different route: **your Mac already has authenticated read/write access to all your calendars** through Internet Accounts (Exchange, Google, iCloud, ICS subscriptions). It reads everything locally via EventKit and maintains "Busy" blocker events in your target calendars. macOS syncs them upstream through the accounts you already have. No SaaS, no OAuth consent, no API keys, nothing leaves your machine.

## How it works

For each target calendar:

1. Collect busy intervals from its source calendars and merge overlaps.
2. Subtract whatever the target already shows as busy (so a meeting you were invited to in both orgs isn't double-blocked).
3. Reconcile the remainder against existing blockers — created and deleted, never edited, keyed by a marker line in the event notes. Idempotent; duplicate or time-drifted blockers self-heal on the next pass.

Skipped by design: all-day events (vacations and FYI banners aren't meetings), declined invites, events marked free, titles matching `skipTitleContains` (informational events like "working from home"), and calsync's own blockers.

## Install

Requires macOS 14+ and Xcode command line tools.

```sh
swift build -c release
mkdir -p ~/bin && cp .build/release/calsync ~/bin/

# config — see below
mkdir -p ~/.config/calsync && $EDITOR ~/.config/calsync/config.json

# first run: approve the calendar-access prompt, sanity-check the plan
~/bin/calsync --dry-run

# run every 15 min via launchd
sed "s/USERNAME/$USER/g" local.calsync.plist > ~/Library/LaunchAgents/local.calsync.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.calsync.plist
```

## Config

`~/.config/calsync/config.json`. Calendar names are matched exactly against Apple Calendar's sidebar names (ambiguous names are an error).

```json
{
  "horizonDays": 56,
  "blockerTitle": "Busy",
  "minBlockMinutes": 5,
  "skipTitleContains": ["working from home", "WFH"],
  "targets": [
    {
      "calendar": "Calendar",
      "sources": ["Client B", "Personal"]
    },
    {
      "calendar": "Client B",
      "sources": ["Calendar", "Personal"]
    }
  ]
}
```

| Key | Default | Meaning |
|-----|---------|---------|
| `horizonDays` | 56 | How far ahead to mirror |
| `blockerTitle` | `Busy` | Title of created blocker events |
| `minBlockMinutes` | 5 | Drop busy fragments shorter than this |
| `skipTitleContains` | `[]` | Source events whose title contains any of these (case-insensitive) are ignored |
| `targets` | — | Each target gets blockers covering its sources' busy time |

Removing a source (or emptying the list) deletes the blockers it produced on the next run — reconciliation always converges to what the config describes.

`--dry-run` prints the planned create/delete set without touching anything.

## Notes

- **Permissions**: first run prompts for calendar access. When run via launchd the binary is its own TCC identity, so the prompt appears once more on first scheduled run — click Allow.
- **Read-only calendars work as sources** — e.g. an ICS-published calendar from a tenant that's browser-only. Lag depends on the publisher's refresh rate.
- **Targets must be writable** (Exchange, Google/CalDAV, iCloud accounts signed into macOS).
- **Failures notify**: fatal errors (renamed calendar, denied access) attempt to post a macOS notification, since nobody reads launchd logs.
- **Run it on an always-on Mac** if you have one; the Mac must be awake to sync.
- Log: `~/Library/Logs/calsync.log`.

## License

MIT

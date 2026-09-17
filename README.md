# Productivity Apps for Mars

Three productivity apps I designed and built for my own daily use: a habit and progress tracker, a focus timer with optional Screen Time blocking, and a calendar and task manager. Mars is my name, not the planet. The apps share a wine-red, white, and blush palette.

| App | Purpose | Platforms |
| --- | --- | --- |
| [Mars Momentum](mars-momentum/README.md) | Study, gym, cardio, weight, goals, and progress | iOS 17+, macOS 14+, browser/PWA |
| [Mars Focus](mars-focus/README.md) | Focus sessions, Pomodoro, schedules, and an optional AI coach | iOS 17+, Mac Catalyst 14+, browser/PWA |
| [Mars Calendar](mars-calendar/README.md) | Calendar events, Reminders, quick add, and a task dashboard | iOS 17+, macOS 14+ |

<p>
  <img src="docs/screenshots/momentum-today.png" alt="Mars Momentum: today's goals and log" width="240">
  <img src="docs/screenshots/focus-session.png" alt="Mars Focus: an active focus session" width="240">
  <img src="docs/screenshots/calendar-list.png" alt="Mars Calendar: agenda with tasks, events, and weather" width="240">
</p>

The iPhone apps running with their built-in demo data. Each app's README has more screenshots.

## Highlights

- **No third-party libraries.** About 15,000 lines of Swift and 4,000 lines of JavaScript, using only Apple frameworks, browser APIs, and the Node standard library. There are no packages to install and the web apps have no build step.
- **Offline-first sync in Momentum.** Entries merge by ID, deletions travel as tombstones, and goals resolve by timestamp. Edits made while a request is in flight are reconciled rather than overwritten. The same document model runs in Swift, in the browser, and in a small `node:http` server with scrypt password hashing, bearer sessions, and login rate limiting. See [sync-core.mjs](mars-momentum/MarsMomentumWeb/sync-core.mjs), [server.mjs](mars-momentum/MarsMomentumServer/server.mjs), and [EntryStore.swift](mars-momentum/MarsMomentum/EntryStore.swift).
- **Tests aimed at the hard parts.** More than 40 `node:test` cases cover overlapping syncs, logout and login races, two tabs writing at once, storage failures, and service-worker cache isolation. Swift harnesses compile the production sources with fakes injected for Keychain, notifications, and Screen Time shields. Each app runs its suite with `./tests/run.sh`.
- **A hand-written natural-language parser in Calendar.** `Standup every weekday at 9:30am until Aug 1` becomes a recurring EventKit event with a preview before saving. It is tested against leap days, month ends, and overnight ranges. See [QuickParse.swift](mars-calendar/MarsCalendar/QuickParse.swift).
- **Platform APIs in real use.** Screen Time (FamilyControls and ManagedSettings), EventKit and Reminders, Keychain, service workers, and an IndexedDB lock that coordinates writes across browser tabs.
- **Honest documentation.** Each app's README states what is and is not enforced, synced, or tested.

## Run

You need Xcode 16 or later for the native apps, Node.js 18 or later for the Momentum server (a current Node.js LTS for the tests), and Python 3 for the static web server.

Open the Xcode project in an app's folder to run its native version. Configure a development team to run on a physical iPhone or iPad.

For Mars Momentum's web app and optional sync server:

```sh
node mars-momentum/MarsMomentumServer/server.mjs
```

Open `http://localhost:8473`.

For Mars Focus's web app:

```sh
python3 -m http.server 8471 --bind 127.0.0.1 -d mars-focus/MarsFocusWeb
```

Open `http://localhost:8471`. PWA installation and offline caching require HTTPS or localhost.

Each app's README covers its features, setup, storage, limitations, and tests.

## License

[MIT](LICENSE)

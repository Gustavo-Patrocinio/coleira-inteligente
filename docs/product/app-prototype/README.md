# App prototype (clickable, sample data)

A clickable prototype of the owner app, used to decide which screens and numbers matter
before building the Flutter app (Phases 3–4). All data is made up.

| Screen | File | What it shows |
|---|---|---|
| Today | `Main.dc.html` | 24 h timeline by behavior; Exercise, Sleep and Skin indicators against the dog's normal; moments of the day |
| Sleep | `Sleep.dc.html` | the night in detail (asleep / lying awake / got up), awakenings, longest stretch, naps, experimental breathing rate, last 7 nights |
| Trends | `Trends.dc.html` | active time and scratching per day with the normal band, 7/30-day toggle, restless nights |
| Alerts | `Alerts.dc.html` | alerts in plain language with "made sense / false alarm" feedback, notification preferences, how alerts work |
| Collar | `Collar.dc.html` | battery, wireless update, fit and comfort, skin-check reminder, record a training session with video |

## Viewing it

The live, clickable version is a Claude design canvas:
https://claude.ai/artifact/GAd3E31xRtwBfqTvKXkJyu (private until shared from its Share menu).

The `.dc.html` files here are its source. They are written for the canvas runtime
(`support.js`, `{{holes}}`, `<sc-for>`), so they do not open as standalone pages; they are
kept in the repo as the reference for screens, copy and layout. `canvas.json` is the
canvas layout.

## Design notes

- Class colors match the labeler: still `#4C78A8`, walking `#54A24B`, running `#F58518`,
  scratching `#E45756`.
- Every number is compared against the dog's own normal; orange marks "out of range".
- Indicator choices and their rationale: [../indicators.md](../indicators.md).

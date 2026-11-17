# Collar Labeler

A web tool to label sessions: video and IMU signal side by side, driven by keyboard
shortcuts. Plain HTML + JS, nothing to install: **open `index.html` in Chrome or Edge**.
Internet is only needed to fetch uPlot (charts) from the CDN.

## Workflow

1. **Open session folder** and pick the folder with `imu.csv`, `meta.json` and the video
   (format from contracts 4.4–4.5).
2. **Sync** (ADR 0003):
   - pause on the frame where the hand hits the case (first tap at the start) →
     *start / video: mark*;
   - click *start / signal: mark*, then the peak on the chart (the click snaps to the
     nearest peak, ±0.5 s);
   - repeat for the first tap at the **end**. With start + end, clock drift is corrected.
3. **Label** while watching: a class key starts a segment, another key closes the current
   one and starts the next, the same key or `Enter` closes it. `I` marks it as uncertain
   (confidence 0.5), `Del` deletes the segment under the cursor.
4. **Export labels** writes `<session_id>.csv` in the contract 4.6 format (it goes into
   `ml/data/labels/`). **Export meta.json** saves the taps under `sync_taps`.

Work is kept as a draft in this browser (per `session_id`). Still, export when you are
done: the draft is lost if the site data is cleared.

| Key | Action |
|---|---|
| `0`–`6` | still, walking, running, scratching, shaking, eating, drinking |
| `x` | unknown / transition (255) |
| `Space` | play/pause |
| `←` `→` | ±1 s (`Shift`: ±5 s) |
| `,` `.` | ±1 frame |
| `[` `]` | speed (0.25× to 4×) |
| `Z` | chart window (10 s / 30 s / 120 s / all) |

The *Session* panel shows the measured ODR and the **packet loss** (Phase 1 criterion:
< 1%). The legend adds up minutes per class and turns green when a class 0–4 passes 3 min.

## Testing without hardware

```bash
cd ml
uv run python scripts/make_synthetic_session.py
```

The script creates `ml/data/raw/synthetic_demo/` with a real signal from the public
dataset, a video that shows the behavior on screen and flashes on the taps, and ground
truth (`labels_truth.csv`). It simulates a late video start, clock drift, packet loss and
`seq` wrap-around.

## Code

- `core.js`: pure logic (timeline, sync, segments, export), no DOM.
- `app.js`: UI (video, uPlot, keyboard).
- Logic tests: `node --test tools/labeler/test/core.test.js`.

Both are classic scripts (no `import`), because ES modules do not load in pages opened
via `file://`.

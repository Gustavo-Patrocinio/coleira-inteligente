"""Feasibility check: can a neck-mounted IMU see breathing? (public dataset, no ground truth)

Usage (from ml/):
    uv run python scripts/breathing_feasibility.py

Two tests on 30 s windows of the raw 100 Hz collar signal:
- Positive control: lying down AND panting. Panting is fast, strong breathing; a clear
  spectral peak at 2–8 Hz means the collar does see respiratory movement.
- Calm breathing: lying down, NOT panting, nothing else going on. We look for a peak at
  0.13–1.2 Hz (8–72/min) and compare its strength with AR(1) red-noise surrogates matched
  to each window. Real breathing should (a) beat the surrogates, (b) fall in the plausible
  resting range (~15–40/min), not at the band edge, and (c) stay stable from one window to
  the next.

Writes docs/results/breathing_feasibility.md and a figure in docs/results/figures/.
"""

from __future__ import annotations

from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
import numpy as np  # noqa: E402
import pandas as pd  # noqa: E402

from coleira_ml.breathing import ar1_surrogate, bandpass, dominant_rate  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
CSV = ROOT / "ml" / "data" / "public" / "DogMoveData.csv"
OUT_MD = ROOT / "docs" / "results" / "breathing_feasibility.md"
FIG = OUT_MD.parent / "figures" / "breathing_feasibility.png"
FS = 100.0
WIN_S = 30
CALM_BAND = (0.13, 1.2)
PANT_BAND = (1.0, 8.0)
PLAUSIBLE = (0.25, 0.67)  # 15–40 breaths/min at rest
N_SURROGATES = 5
CH = ["ANeck_x", "ANeck_y", "ANeck_z", "GNeck_x", "GNeck_y", "GNeck_z"]
U = "<undefined>"


def load_states() -> pd.DataFrame:
    cols = ["DogID", "TestNum", *CH, "Behavior_1", "Behavior_2", "Behavior_3"]
    df = pd.read_csv(CSV, usecols=cols)
    b = df[["Behavior_1", "Behavior_2", "Behavior_3"]]
    lying = (b == "Lying chest").any(axis=1)
    panting = (b == "Panting").any(axis=1)
    only = b.isin(["Lying chest", "Panting", U]).all(axis=1)  # nothing else going on
    df["state"] = np.select(
        [lying & only & ~panting, lying & only & panting], ["calm", "panting"], default=""
    )
    change = (
        (df.state != df.state.shift())
        | (df.DogID != df.DogID.shift())
        | (df.TestNum != df.TestNum.shift())
    )
    df["seg"] = change.cumsum()
    return df[df.state != ""]


def analyze(df: pd.DataFrame, rng: np.random.Generator) -> pd.DataFrame:
    w = int(WIN_S * FS)
    rows = []
    for (seg, state), g in df.groupby(["seg", "state"]):
        x = g[CH].to_numpy(float)
        for k, i in enumerate(range(0, len(x) - w + 1, w)):
            win = x[i : i + w]
            motion = float(np.std(np.linalg.norm(win[:, :3], axis=1)))
            if state == "calm":
                peak = dominant_rate(bandpass(win, FS, 0.1, 1.5), FS, CALM_BAND)
                sur = [
                    dominant_rate(bandpass(ar1_surrogate(win, rng), FS, 0.1, 1.5), FS, CALM_BAND)
                    for _ in range(N_SURROGATES)
                ]
                sur_snr = float(np.max([s.snr for s in sur]))
            else:
                peak = dominant_rate(win, FS, PANT_BAND)
                sur_snr = float("nan")
            rows.append(
                dict(state=state, dog=int(g.DogID.iloc[0]), seg=seg, k=k, freq=peak.freq_hz,
                     snr=peak.snr, sur_snr=sur_snr, channel=CH[peak.channel], motion=motion)
            )  # fmt: skip
    return pd.DataFrame(rows)


def example(df: pd.DataFrame, r: pd.DataFrame, state: str) -> tuple[np.ndarray, str]:
    row = r[r.state == state].sort_values("snr").iloc[len(r[r.state == state]) // 2]
    g = df[df.seg == row.seg]
    i = int(row.k * WIN_S * FS)
    x = g[row.channel].to_numpy(float)[i : i + int(10 * FS)]  # first 10 s of that window
    lo, hi = (0.1, 1.5) if state == "calm" else (1.0, 8.0)
    return bandpass(x[:, None] - x.mean(), FS, lo, hi)[:, 0], row.channel


def main() -> None:
    rng = np.random.default_rng(0)
    df = load_states()
    r = analyze(df, rng)
    calm, pant = r[r.state == "calm"], r[r.state == "panting"]

    beats = calm.snr > calm.sur_snr
    plaus = calm.freq.between(*PLAUSIBLE)
    edge = calm.freq <= CALM_BAND[0] + 0.02
    steps = calm.sort_values(["seg", "k"]).groupby("seg").freq.diff().abs().dropna()

    # ---- figure
    fig, ax = plt.subplots(2, 2, figsize=(11, 6.5))
    ax[0, 0].hist(calm.freq * 60, bins=np.arange(6, 74, 2), color="#4C78A8")
    ax[0, 0].axvspan(PLAUSIBLE[0] * 60, PLAUSIBLE[1] * 60, color="#54A24B", alpha=0.15,
                     label="plausible resting rate")  # fmt: skip
    ax[0, 0].set_title("Calm lying: dominant rate per 30 s window")
    ax[0, 0].set_xlabel("breaths/min")
    ax[0, 0].legend(fontsize=8)
    ax[0, 1].hist(pant.freq * 60, bins=np.arange(60, 480, 15), color="#F58518")
    ax[0, 1].set_title("Lying + panting: dominant rate (positive control)")
    ax[0, 1].set_xlabel("breaths/min")
    xc, chc = example(df, r, "calm")
    xp, chp = example(df, r, "panting")
    t = np.arange(len(xc)) / FS
    ax[1, 0].plot(t, xc * (1000 if chc.startswith("A") else 1), color="#4C78A8", lw=1)
    ax[1, 0].set_title(f"Calm lying, median window ({chc}, 0.1–1.5 Hz)")
    ax[1, 0].set_xlabel("s")
    ax[1, 0].set_ylabel("mg" if chc.startswith("A") else "°/s")
    ax[1, 1].plot(t, xp * (1000 if chp.startswith("A") else 1), color="#F58518", lw=1)
    ax[1, 1].set_title(f"Lying + panting, median window ({chp}, 1–8 Hz)")
    ax[1, 1].set_xlabel("s")
    ax[1, 1].set_ylabel("mg" if chp.startswith("A") else "°/s")
    fig.tight_layout()
    FIG.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(FIG, dpi=110)
    plt.close(fig)

    q = lambda s, ps: ", ".join(f"{v:.0f}" for v in s.quantile(ps))  # noqa: E731
    md = f"""# Breathing feasibility on the public dataset

> Generated by `ml/scripts/breathing_feasibility.py`. Do not edit by hand.

Question: can a neck-mounted IMU see breathing? The public dataset has no breathing ground
truth, so this only checks whether a **plausible, periodic** signal exists. Raw 100 Hz
collar signal, 30 s windows, all 6 channels (the strongest one is used per window).

## Positive control: lying down + panting

- {len(pant)} windows from {pant.dog.nunique()} dogs.
- Dominant rate (10th / 50th / 90th percentile): **{q(pant.freq * 60, [0.1, 0.5, 0.9])} per min**
  (canine panting is typically a few hundred per minute).
- Peak SNR median: **{pant.snr.median():.0f}**.
- **Verdict: the collar clearly sees panting.** Strong, fast respiratory movement produces
  a sharp spectral peak.

## Calm breathing: lying down, not panting

- {len(calm)} windows from {calm.dog.nunique()} dogs (median movement std of |a|:
  {calm.motion.median() * 1000:.1f} mg).
- Dominant rate (10th / 50th / 90th percentile): {q(calm.freq * 60, [0.1, 0.5, 0.9])} per min.
- Peak stronger than all {N_SURROGATES} matched red-noise surrogates: **{beats.mean():.0%}**
  of windows.
- Peak inside the plausible resting range (15–40/min): **{plaus.mean():.0%}**; stuck at the
  lower band edge: **{edge.mean():.0%}** (a sign of slow drift, not breathing).
- Plausible **and** beating the surrogates: **{(beats & plaus).mean():.0%}**.
- Median change of the dominant rate between consecutive windows of the same lying
  stretch: {steps.median() * 60:.1f} per min (n = {len(steps)}).

**Verdict: inconclusive, leaning negative.** {beats.mean():.0%} of windows contain a peak
stronger than matched red noise, but it sits at {calm.freq.median() * 60:.0f}/min with
{edge.mean():.0%} of them pinned to the lower edge of the band, which is what slow drift
shaped by the band-pass filter looks like. Only {plaus.mean():.0%} fall in the plausible
resting range. It could also be very slow breathing in deeply resting dogs, which this
dataset cannot confirm without ground truth.

![Breathing feasibility](figures/breathing_feasibility.png)

## What this means for the project

- **Panting detection is feasible now** and is useful on its own (heat stress, pain,
  anxiety). The dataset has 296 min of `Panting` labels, so it could become a new class
  (new ID + ADR), probably as an event/flag inside `still`.
- **Resting respiratory rate stays experimental.** This dataset is a weak test: the
  ActiGraph is not our sensor, mounting tightness is unknown, and "lying chest" includes
  awake dogs adjusting posture. The real test is Phase 1 night recordings, counting breaths
  on video. Things to try then: a snug collar, the gyroscope, a more sensitive
  accelerometer range during sleep sampling (e.g. ±2 g, reconfigured at runtime), longer
  windows, and only deep-stillness stretches.
"""
    OUT_MD.write_text(md, encoding="utf-8")
    print(md)


if __name__ == "__main__":
    main()

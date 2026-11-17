# Build guide: prototype collar v1

From parts on the table to a collar on the dog, in about 2 hours. You need basic soldering
(two wires). Each step ends with a check: if a check fails, stop and fix it before going on.

> **Safety first.** A lithium cell on an animal is the riskiest part of this project. Follow
> the battery rules in step 2 every time, charge with the collar **off** the dog, and never
> leave the dog alone wearing the prototype (it is not sealed or bite-proof).

## 1. Parts and tools

| Part | Notes |
|---|---|
| Seeed XIAO nRF52840 **Sense** | the *Sense* variant has the IMU; the plain one does not |
| 3.7 V LiPo **502030** (~250 mAh) **with protection board (PCM)** | 30 × 20 × 5 mm; the small PCB under the tape at the wire end is the protection; no PCM, no buy |
| 2 × M2 × 6 mm self-tapping screws | pan or flat head |
| Thin double-sided foam tape (~0.8 mm) | between board and battery, and to hold the battery |
| Kapton tape | insulates the solder joints |
| Printed case (`hardware/cad`) | base for your collar width + lid, PETG |
| A flat collar (16, 20 or 25 mm wide, ≤ 2.6 mm thick) | nylon is ideal; buckle collar, not a choke chain |

Tools: soldering iron (fine tip, ~330 °C), solder with flux, **multimeter**, flush cutters,
tweezers, small Phillips screwdriver, USB-C cable (data, not charge-only).

## 2. Battery rules (read once, apply always)

1. **Check the polarity with the multimeter before soldering.** Red is *usually* +, but cheap
   cells ship with swapped colors. Probe the wires: the meter must read about +3.7 to +4.2 V
   with the red probe on the wire you will call BAT+.
2. Never let the two wires touch. Cut and solder **one wire at a time**, and cover the other
   end with tape while you work.
3. A cell that is swollen, dented, hot or smells sweet goes to battery recycling, never into
   a collar.
4. Charge only on a non-flammable surface, while someone is around, collar off the dog.
5. No water: no baths, rain walks or swimming with the prototype.

## 3. Check the board before soldering anything

Flash the logger firmware and confirm the IMU streams (details in `firmware/logger/README.md`):

1. Plug the XIAO into the computer, **double-tap** the tiny reset button: a drive named
   `XIAO-SENSE` appears.
2. Copy `zephyr.uf2` (logger build) onto it. The board reboots.
3. `cd ml && uv run python scripts/record_ble.py --dog test --minutes 1`, and shake the board.

**Check:** it connects, packet loss < 1%, and the numbers change when you move the board. If
not, the problem is the board or the firmware, not your soldering: much easier to find now.

## 4. Solder the battery

The XIAO has no battery connector: the **BAT+ and BAT− pads are on the underside** (labeled
on the silkscreen; confirm on Seeed's pinout picture for your board revision before soldering).

1. Cut the battery wires to ~30 mm (one at a time, rule 2). Strip 1.5 mm, tin the ends.
2. Tin the two pads lightly. Solder BAT+ (the wire that read +3.7 V) to **BAT+**, then BAT−
   to **BAT−**. Keep the joints flat: they sit in the 1.2 mm gap under the board in the case.
3. Cover both joints with Kapton.

**Check:** unplug USB. With the multimeter on the 3V3 pin vs GND, you read ~3.3 V (the board
runs from the battery). Plug USB: the small charge LED near the USB-C lights while charging
and goes off when full. A 250 mAh cell takes ~5 h at the XIAO's default 50 mA charge current.

> The firmware never drives pin P0.14 high: on this board that pin enables the battery
> voltage divider, and driving it high while charging can damage the input. If you write
> your own firmware, keep that rule.

## 5. Print the case

Print `base_strapXXmm.stl` for your collar width and `lid.stl` (settings in
`hardware/cad/README.md`: PETG, 4 perimeters, no supports).

**Check:** the collar slides through the tunnel without forcing; the lid drops into the base
with light friction; the M2 screws bite into the ear holes (pre-thread them once before
assembly). If the lid is too tight, sand the lip or set `fit` higher in `Params` and reprint.

## 6. Assemble

1. Flash the **collar firmware** (`firmware/app`, same double-tap + copy) now, while the board
   is easy to reach. (Later updates go over the air, Phase 3.)
2. Put the XIAO in the base, components up, **USB-C facing the side slot**, resting on the two
   rails; the battery wires run under it.
3. A piece of foam tape on top of the board's components, then the battery on the tape, wires
   folded in the gap at the end. Nothing should press on the reset button.
4. Lid on, arrow visible, two screws, snug but not forced (PETG cracks).

**Check:** plug a USB-C cable through the slot: the plug seats fully (it clicks) and the
computer sees the board. Shake the closed case: nothing rattles.

## 7. Pair and verify

1. Open the app, sign in, accept the privacy notice, add your dog, **Pair collar** (the collar
   advertises as `Collar`).
2. Leave it on the table 10 minutes, then **Sync now**: you should see ~10 minutes synced and a
   still block on the timeline.

**Check:** the minutes arrive and the Today screen shows them. If sync fails, keep the phone
within 1–2 m and retry; then look at the serial log (`firmware/app/README.md`).

## 8. Put it on the dog

1. Thread the collar through the tunnel, device **under the neck**, **arrow pointing to the
   head**. Always the same way: the model was trained like that (contract 4.2).
2. Fit: **two fingers** between collar and neck. Too loose and the device swings (noisy data,
   rubbing); too tight is uncomfortable.
3. First days: short periods (adaptation, `docs/protocols/collection.md`), check the skin under
   the device daily for redness or hair loss in the first week, then weekly. Any irritation:
   stop and pad or reshape the case.

Weight: ~20 g in total, under 3% of body weight for dogs from about 0.7 kg; for small dogs
prefer the 16 mm variant and a light collar.

## What next

- Day-to-day: the phone syncs whenever the app is opened near the collar; a home base
  station that syncs on its own comes in Phase 4.
- Want to help the model? Record sessions with **Help improve recognition** in the app
  (`docs/protocols/collection.md`).
- Problems or ideas: open an issue with a photo of your build.

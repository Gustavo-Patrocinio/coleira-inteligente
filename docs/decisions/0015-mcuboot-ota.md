# ADR 0015: MCUboot with the update slot in external flash, OTA as a build variant

- **Status:** accepted (built, not yet run on a board)
- **Date:** 2026-11-17
- **Contracts affected:** none (BLE adds the standard MCUmgr SMP service; 4.4/4.7/4.8 unchanged)

## Context

From Phase 3 on, every firmware must keep OTA working (CLAUDE.md rule 4): a collar in a sealed
case on a dog cannot be reflashed over USB. The XIAO nRF52840 Sense ships with Adafruit's UF2
bootloader, which only updates over USB. MCUboot is NCS's bootloader and pairs with MCUmgr
(SMP over BLE), which phones already speak (nRF Connect Device Manager, Android and iOS).

The internal flash is 1 MB. MCUboot needs two image slots of the same size; the app is ~324 KB
and the summary partition is 416 KB (~13 days, ADR 0013). Two internal slots would leave
`(1024 − 48 − 416) / 2 = 280 KB` each: too small. The board also has a 2 MB QSPI flash
(P25Q16H) that nothing uses.

## Decision

- **MCUboot at 0x0 (48 KB), running slot internal (560 KB), summaries internal (416 KB), update
  slot in the QSPI flash (560 KB).** Layout in `firmware/app/ota/pm_static.yml`; same
  `storage_partition` name, so `summary_store.c` is unchanged. MCUboot default mode for nRF52
  (swap using move): an update can be tested and is reverted unless confirmed.
- **The new image confirms itself** 30 s after a full start (IMU, storage, BLE, model all up;
  `src/ota.c`). An image that cannot start goes back to the previous one on the next reset.
- **OTA is a build variant, not the default.** The default build keeps the UF2 bootloader, so
  anyone without an SWD probe can still flash by drag-and-drop. The OTA variant needs an SWD
  probe once (Raspberry Pi Pico as debugprobe + pyOCD) to erase the chip and write MCUboot;
  after that, updates go over BLE. MCUboot is built without USB or logs to fit in 48 KB.
- **Images are signed with ECDSA P-256.** The default key is MCUboot's public development key
  (fine for the bench). Collars that leave the bench use a private key passed at build time
  and kept out of git.

## Alternatives

- **Both slots internal:** shrink storage to ~150 KB (~7 days) or the app slot below 280 KB.
  Loses buffer days or blocks model growth.
- **Summaries in QSPI, slots internal:** keeps the swap internal, but the store would need the
  QSPI driver on (power) on every write and a new partition device; the update slot is written
  only during an update.
- **Keep Adafruit's bootloader and its BLE DFU:** its OTA uses the old Nordic DFU protocol and
  the SoftDevice layout, which Zephyr does not use.
- **Overwrite-only MCUboot:** smaller and simpler, but no revert: a bad image would brick the
  collar until someone opens the case.

## Consequences

- One more piece of hardware to set up the first OTA collar (the SWD probe, already ordered).
  The guide is in `firmware/app/README.md` (OTA section).
- The SMP service is open to any phone in range, like the sync service; only correctly signed
  images boot. With the development key anyone can sign, so the private key is a must before
  beta collars. Pairing/bonding for SMP is a later hardening step.
- Switching a collar between the UF2 and OTA layouts erases the stored summaries (sync first).
- Flash cost in the app: ~14 KB for MCUmgr; RAM +18 KB (larger BLE buffers for faster uploads).

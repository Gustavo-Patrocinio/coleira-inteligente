# Collar logger firmware (Phase 1)

Streams raw IMU data from the Seeed XIAO nRF52840 Sense over BLE so we can record and label
sessions. Packet format: contract 4.4; GATT service and sampling: ADR 0010.

- IMU: LSM6DS3TR-C at 104 Hz, ±16 g, ±2000 dps, read every 20 ms by a kernel timer
  (≈ 50 Hz on the MCU crystal).
- 10 samples per packet → 128-byte notifications, 5 packets/s.
- Samples only while a client is subscribed; advertises as `Collar-Logger`.
- Logs over the USB serial port in development builds; `release.conf` turns them off.

> ⚠️ Written before the hardware arrived: it **builds** but has **not run on a board yet**.
> Check items below off as they are verified.

## Status

- [x] Builds with nRF Connect SDK v2.9.0 for `xiao_ble/nrf52840/sense` (2026-11-17):
      dev build 0 warnings (FLASH 187 KB / 18%, RAM 58 KB / 23%); release build 1 harmless
      warning from the board's defconfig (FLASH 149 KB, RAM 46 KB). Verified in the
      generated config: accel ±16 g, gyro ±2000 dps, ODR 104 Hz, MTU 247, flash offset
      0x27000 (UF2 bootloader), IMU node `st,lsm6dsl` @ 0x6A with its power regulator
- [ ] Boots, IMU found (`IMU ... ready` on the serial log)
- [ ] Advertises; `ml/scripts/record_ble.py` connects and receives packets
- [ ] MTU ≥ 131 negotiated with the PC and with a phone
- [ ] Packet loss < 1% over 15 min at 2–3 m
- [ ] Values make sense: ~1 g on one axis at rest, ~0 dps when still, taps visible

## 1. Install the SDK (once)

Command line, any editor (this is what was used; Git Bash on Windows):

```bash
mkdir -p ~/.local/bin
curl -L -o ~/.local/bin/nrfutil.exe https://files.nordicsemi.com/artifactory/swtools/external/nrfutil/executables/x86_64-pc-windows-msvc/nrfutil.exe
~/.local/bin/nrfutil.exe install sdk-manager
~/.local/bin/nrfutil.exe sdk-manager install v2.9.0     # toolchain + SDK into C:\ncs (~30 min)
```

The "unable to create symlinks" warning at the end only affects Matter/Memfault examples,
not this firmware. Alternatives: **nRF Connect for VS Code** (*Manage toolchains/SDKs* →
v2.9.0), or a west workspace from `firmware/west.yml` (see the comments in that file).

## 2. Build

Run from the SDK folder, with a **short build path** (Windows has a 260-character path
limit and deep build folders fail with "opening dependency file ... No such file"):

```bash
cd /c/ncs/v2.9.0
APP=C:/Users/<you>/Documents/projetos/coleira-inteligente/firmware/logger
~/.local/bin/nrfutil.exe sdk-manager toolchain launch --ncs-version v2.9.0 -- \
  west build -p always -b xiao_ble/nrf52840/sense -d C:/ncs/b/logger "$APP"

# release (no logs, no USB serial):
~/.local/bin/nrfutil.exe sdk-manager toolchain launch --ncs-version v2.9.0 -- \
  west build -p always -b xiao_ble/nrf52840/sense -d C:/ncs/b/logger-rel "$APP" -- -DEXTRA_CONF_FILE=release.conf
```

The file to flash is `C:/ncs/b/logger/logger/zephyr/zephyr.uf2`.

## 3. Flash (no debugger needed)

The XIAO ships with a UF2 bootloader:

1. Connect the XIAO by USB-C (a **data** cable).
2. Double-tap the tiny reset button: a drive called `XIAO-SENSE` appears.
3. Copy `C:/ncs/b/logger/logger/zephyr/zephyr.uf2` onto that drive. The board reboots into
   the logger.

The SWD probe (Raspberry Pi Pico) is only needed later for debugging and for MCUboot
(Phase 3).

## 4. Check it works

- Serial log: open the XIAO's COM port at any baud rate (e.g. with the nRF Connect *Serial
  Terminal*). You should see `IMU ... ready`, `advertising as "Collar-Logger"`.
- Phone: in **nRF Connect for Mobile**, scan, connect to `Collar-Logger`, enable notifications
  on the `c01a0001-...` characteristic: 128-byte values arrive 5 times per second.
- PC recording (writes a session folder in the contract 4.5 format):

  ```bash
  cd ml
  uv run python scripts/record_ble.py --dog test --minutes 2
  ```

  Then open the folder in `tools/labeler`: the measured ODR should read ≈ 50 Hz and the loss
  < 1%.

## Code map

| File | What it does |
|---|---|
| `src/main.c` | sampler thread (20 ms timer → 10-sample packets → queue) and sender thread (queue → BLE) |
| `src/imu.c` | IMU through Zephyr's sensor API, converted to int16 at ±16 g / ±2000 dps |
| `src/ble_raw.c` | advertising, GATT service, MTU/PHY/connection-interval requests, notify |
| `src/packet.c` | packs contract 4.4 packets (mirrored and tested in `ml/src/coleira_ml/raw_packet.py`) |
| `prj.conf` / `release.conf` | Kconfig for development / release |

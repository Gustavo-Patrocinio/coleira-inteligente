# Collar logger firmware (Phase 1)

Streams raw IMU data from the Seeed XIAO nRF52840 Sense over BLE so we can record and label
sessions. Packet format: contract 4.4; GATT service and sampling: ADR 0010.

- IMU: LSM6DS3TR-C at 104 Hz, ±16 g, ±2000 dps, read every 20 ms by a kernel timer
  (≈ 50 Hz on the MCU crystal).
- 10 samples per packet → 128-byte notifications, 5 packets/s.
- Samples only while a client is subscribed; advertises as `Collar-Logger`.
- Logs over the USB serial port in development builds; `release.conf` turns them off.

> ⚠️ Written before the hardware arrived: it has **not been built or run yet**. Expect
> small fixes on first build (Kconfig names and devicetree details differ between SDK
> versions). Check items below off as they are verified.

## Status

- [ ] Builds with nRF Connect SDK v2.9.0 for `xiao_ble/nrf52840/sense`
- [ ] Boots, IMU found (`IMU ... ready` on the serial log)
- [ ] Advertises; `ml/scripts/record_ble.py` connects and receives packets
- [ ] MTU ≥ 131 negotiated with the PC and with a phone
- [ ] Packet loss < 1% over 15 min at 2–3 m
- [ ] Values make sense: ~1 g on one axis at rest, ~0 dps when still, taps visible

## 1. Install the SDK (once)

Easiest: **nRF Connect for VS Code** → *Manage toolchains* → install **v2.9.0** →
*Manage SDKs* → install **v2.9.0**. Then *Open an existing application* →
`firmware/logger`.

Command line alternative (keeps the SDK outside this repo):

```bash
mkdir collar-ws && cd collar-ws
git clone https://github.com/Gustavo-Patrocinio/coleira-inteligente.git
west init -l coleira-inteligente --mf firmware/west.yml
west update
```

## 2. Build

```bash
west build -b xiao_ble/nrf52840/sense coleira-inteligente/firmware/logger
# release (no logs):
west build -b xiao_ble/nrf52840/sense coleira-inteligente/firmware/logger -- -DEXTRA_CONF_FILE=release.conf
```

## 3. Flash (no debugger needed)

The XIAO ships with a UF2 bootloader:

1. Connect the XIAO by USB-C (a **data** cable).
2. Double-tap the tiny reset button: a drive called `XIAO-SENSE` appears.
3. Copy `build/logger/zephyr/zephyr.uf2` (or `build/zephyr/zephyr.uf2`) onto that drive. The
   board reboots into the logger.

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

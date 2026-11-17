"""Record a session from the collar logger over BLE, on a PC (no phone app needed).

Usage (from ml/):
    uv run python scripts/record_ble.py --dog thor            # until Ctrl+C
    uv run python scripts/record_ble.py --dog thor --minutes 15

Film the dog with any phone at the same time and do the 3 taps on the case at the start
and at the end (docs/protocols/collection.md). The labeler aligns video and IMU from the
taps (ADR 0003), so the phone does not need to be synced with the PC.

Writes ml/data/raw/<session_id>/imu.csv (contract 4.5) and meta.json. Put the video file
in the same folder and fill in `video_file` before labeling.
"""

from __future__ import annotations

import argparse
import asyncio
import csv
import json
import time
from datetime import datetime
from pathlib import Path

from bleak import BleakClient, BleakScanner

from coleira_ml import raw_packet as rp
from coleira_ml import sync_protocol as sp

ROOT = Path(__file__).resolve().parents[2]


async def find_logger(timeout: float):
    print(f"scanning for {rp.DEVICE_NAME} ({timeout:.0f} s)...")
    dev = await BleakScanner.find_device_by_filter(
        lambda d, adv: (
            # logger firmware, or the collar firmware in raw dump mode (ADR 0014)
            bool({rp.SERVICE_UUID, sp.SERVICE_UUID} & {u.lower() for u in adv.service_uuids})
            or (d.name or "") in (rp.DEVICE_NAME, sp.DEVICE_NAME)
        ),
        timeout=timeout,
    )
    if dev is None:
        raise SystemExit("collar not found: is it powered, advertising and close to the PC?")
    return dev


async def record(dog: str, minutes: float | None, scan_timeout: float) -> None:
    start = datetime.now()
    session_id = f"{start:%Y%m%d-%H%M}-{dog}"
    out = ROOT / "ml" / "data" / "raw" / session_id
    out.mkdir(parents=True, exist_ok=True)
    meta = {
        "session_id": session_id,
        "dog_id": dog,
        "device_id": "",
        "start_phone_ts": int(time.time() * 1000),
        "video_file": "",
        "video_start_phone_ts_ms": None,
        "accel_range": 16,
        "gyro_range": 2000,
        "odr_hz": 50,
        "location": "",
        "surface": "",
        "notes": "recorded with ml/scripts/record_ble.py",
        "sync_taps": {},
    }

    dev = await find_logger(scan_timeout)
    meta["device_id"] = dev.address
    loss = rp.LossCounter()
    bad = 0
    t0 = time.monotonic()

    with (out / "imu.csv").open("w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(rp.CSV_HEADER)

        def on_packet(_char, data: bytearray) -> None:
            nonlocal bad
            now_ms = int(time.time() * 1000)
            try:
                pkt = rp.parse(bytes(data))
            except ValueError as e:
                bad += 1
                print(f"bad packet ({e})")
                return
            loss.add(pkt.seq)
            writer.writerows(rp.csv_rows(pkt, now_ms))

        async with BleakClient(dev) as client:
            print(f"connected to {dev.name} [{dev.address}], MTU {client.mtu_size}")
            if client.mtu_size < rp.PACKET_SIZE + 3:
                print(f"warning: MTU {client.mtu_size} < {rp.PACKET_SIZE + 3}; packets may fail")
            await client.start_notify(rp.RAW_CHAR_UUID, on_packet)
            print(f"recording to {out}  (Ctrl+C to stop)")
            try:
                while minutes is None or time.monotonic() - t0 < minutes * 60:
                    await asyncio.sleep(5)
                    f.flush()
                    el = time.monotonic() - t0
                    print(
                        f"  {el:6.0f} s  packets {loss.received}/{loss.expected}  "
                        f"loss {loss.loss:.2%}  bad {bad}"
                    )
            except (KeyboardInterrupt, asyncio.CancelledError):
                pass
            finally:
                if client.is_connected:
                    await client.stop_notify(rp.RAW_CHAR_UUID)

    elapsed = time.monotonic() - t0
    rate = loss.received * rp.SAMPLES_PER_PACKET / elapsed if elapsed else 0.0
    meta["notes"] += f"; packet loss {loss.loss:.2%}; ~{rate:.2f} samples/s received"
    (out / "meta.json").write_text(json.dumps(meta, indent=2) + "\n", encoding="utf-8")
    print(f"\ndone: {loss.received} packets, loss {loss.loss:.2%} (target < 1%), {out}")
    print("next: copy the video into that folder, set video_file in meta.json, open the labeler")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--dog", required=True, help="dog code (no personal names of owners)")
    ap.add_argument("--minutes", type=float, default=None, help="stop after N minutes")
    ap.add_argument("--scan-timeout", type=float, default=15.0)
    args = ap.parse_args()
    try:
        asyncio.run(record(args.dog, args.minutes, args.scan_timeout))
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()

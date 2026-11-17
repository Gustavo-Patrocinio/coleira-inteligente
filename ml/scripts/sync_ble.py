"""Home base station emulator on a PC (ADR 0007 / 0013): sync the collar over BLE and upload.

Usage (from ml/):
    uv run python scripts/sync_ble.py --api http://localhost:3000 --token dev_...   # sync + upload
    uv run python scripts/sync_ble.py --dry-run   # sync and print, no upload

What it does, exactly like the future ESP32 base station:
1. finds the collar (advertises "Collar" with the sync service), connects
2. writes the current time (the collar stamps its stored seconds with it)
3. asks for every record since the last uploaded minute (kept in ml/data/sync_state.json)
4. uploads the raw 15-byte records to POST /v1/ingest (idempotent) with the device token
   (from POST /v1/dogs/:id/devices), via = "base_station"
"""

from __future__ import annotations

import argparse
import asyncio
import base64
import json
import time
import urllib.request
from pathlib import Path

from bleak import BleakClient, BleakScanner

from coleira_ml import sync_protocol as sp

STATE = Path(__file__).resolve().parents[1] / "data" / "sync_state.json"


async def sync(scan_timeout: float, since_override: int | None) -> tuple[str, list[bytes]]:
    state = json.loads(STATE.read_text()) if STATE.exists() else {}
    print(f"scanning for {sp.DEVICE_NAME} ...")
    dev = await BleakScanner.find_device_by_filter(
        lambda d, adv: (
            sp.SERVICE_UUID in [u.lower() for u in adv.service_uuids]
            or (d.name or "") == sp.DEVICE_NAME
        ),
        timeout=scan_timeout,
    )
    if dev is None:
        raise SystemExit("collar not found")
    since = since_override if since_override is not None else state.get(dev.address, 0)
    records: list[bytes] = []
    done = asyncio.Event()

    expected: list[int] = []  # filled by the "sync done" status

    def maybe_done() -> None:
        # Status can arrive before the last Data notification: wait for both (same as the app).
        if expected and len(records) >= expected[0]:
            done.set()

    def on_data(_c, data: bytearray) -> None:
        records.extend(sp.split_records(bytes(data)))
        maybe_done()

    def on_status(_c, data: bytearray) -> None:
        st = sp.parse_status(bytes(data))
        if st.kind == sp.KIND_SYNC_DONE:
            print(
                f"collar sent {st.count} records; "
                f"stored {st.oldest_minute_ts}..{st.newest_minute_ts}"
            )
            expected.append(st.count)
            maybe_done()

    async with BleakClient(dev) as client:
        print(f"connected to {dev.name} [{dev.address}], MTU {client.mtu_size}")
        await client.write_gatt_char(sp.TIME_UUID, sp.time_payload(int(time.time())), response=True)
        await client.start_notify(sp.DATA_UUID, on_data)
        await client.start_notify(sp.STATUS_UUID, on_status)
        await client.write_gatt_char(sp.CONTROL_UUID, sp.send_since_payload(since), response=True)
        await asyncio.wait_for(done.wait(), timeout=120)
    return dev.address, records


def upload(api: str, token: str, records: list[bytes]) -> dict:
    body = json.dumps(
        {"records": base64.b64encode(b"".join(records)).decode(), "via": "base_station"}
    )
    req = urllib.request.Request(
        api.rstrip("/") + "/v1/ingest",
        data=body.encode(),
        headers={"content-type": "application/json", "authorization": f"Bearer {token}"},
        method="POST",
    )
    with urllib.request.urlopen(req) as resp:
        return json.load(resp)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--api", default="http://localhost:3000")
    ap.add_argument("--token", help="device token (dev_...) from POST /v1/dogs/:id/devices")
    ap.add_argument("--since", type=int, default=None, help="override: epoch minute to sync from")
    ap.add_argument("--dry-run", action="store_true", help="do not upload")
    ap.add_argument("--scan-timeout", type=float, default=15.0)
    args = ap.parse_args()

    address, records = asyncio.run(sync(args.scan_timeout, args.since))
    decoded = [sp.decode_record(r) for r in records]
    print(f"received {len(records)} records")
    for r in decoded[-5:]:
        print(f"  {time.strftime('%Y-%m-%d %H:%M', time.localtime(r.minute_ts))}  "
              f"seconds={list(r.seconds)} unknown={r.unknown_s} flags={r.flags}")  # fmt: skip
    if args.dry_run or not records:
        return
    if not args.token:
        raise SystemExit("--token is required to upload (or use --dry-run)")
    res = upload(args.api, args.token, records)
    print(f"backend: {res}")
    newest = max(r.minute_ts for r in decoded)
    state = json.loads(STATE.read_text()) if STATE.exists() else {}
    state[address] = newest + 60  # next sync starts after the newest uploaded minute
    STATE.parent.mkdir(parents=True, exist_ok=True)
    STATE.write_text(json.dumps(state, indent=2))


if __name__ == "__main__":
    main()

"""Download the public dataset (Vehkaoja 2022 / Kumpulainen 2021) from Mendeley Data.

Usage (from ml/):
    uv run python scripts/download_public.py

- Uses Mendeley's public API and checks each file's SHA-256.
- Skips files that already exist with the right hash (safe to run again).
- Extracts the CSV zip into data/public/.

Required citations (requested by the authors):
- Vehkaoja et al. (2022), Data in Brief 40, 107822.
- Kumpulainen et al. (2021), Applied Animal Behaviour Science 241, 105393.
"""

from __future__ import annotations

import hashlib
import json
import sys
import urllib.request
import zipfile
from pathlib import Path

DATASET_ID = "vxhx934tbn"
VERSION = 4
WANTED = {"Data_description.txt", "DogInfo.csv", "DogMoveData_csv_format.zip"}
API = f"https://data.mendeley.com/public-api/datasets/{DATASET_ID}/files?folder_id=root&version={VERSION}"
OUT_DIR = Path(__file__).resolve().parents[1] / "data" / "public"
UA = {"User-Agent": "coleira-ml-downloader"}


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def download(url: str, dest: Path, size: int) -> None:
    tmp = dest.with_suffix(dest.suffix + ".part")
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req) as resp, tmp.open("wb") as f:
        done = 0
        while chunk := resp.read(1 << 20):
            f.write(chunk)
            done += len(chunk)
            print(f"\r  {done / 1e6:7.1f} / {size / 1e6:.1f} MB", end="", flush=True)
    print()
    tmp.replace(dest)


def main() -> int:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    with urllib.request.urlopen(urllib.request.Request(API, headers=UA)) as resp:
        files = json.load(resp)

    for meta in files:
        name = meta["filename"]
        if name not in WANTED:
            continue
        details = meta["content_details"]
        dest = OUT_DIR / name
        if dest.exists() and sha256(dest) == details["sha256_hash"]:
            print(f"ok (already there): {name}")
            continue
        print(f"downloading: {name}")
        download(details["download_url"], dest, details["size"])
        if sha256(dest) != details["sha256_hash"]:
            print(f"ERROR: hash mismatch for {name}", file=sys.stderr)
            return 1

    zip_path = OUT_DIR / "DogMoveData_csv_format.zip"
    with zipfile.ZipFile(zip_path) as zf:
        for member in zf.namelist():
            target = (OUT_DIR / member).resolve()
            if not target.is_relative_to(OUT_DIR.resolve()):  # guard against path traversal
                raise RuntimeError(f"suspicious path in zip: {member}")
        zf.extractall(OUT_DIR)
        print("extracted:", ", ".join(zf.namelist()))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

"""Download the public dog IMU datasets from Mendeley Data.

Usage (from ml/):
    uv run python scripts/download_public.py              # all datasets
    uv run python scripts/download_public.py vehkaoja     # just one

- Uses Mendeley's public API and checks each file's SHA-256.
- Skips files that already exist with the right hash (safe to run again).
- Extracts zips inside the dataset folder.

Datasets (see docs/public-dataset.md; cite them when you use them):
- vehkaoja: Vehkaoja et al. (2022) Data in Brief 40, 107822 and Kumpulainen et al. (2021)
  Applied Animal Behaviour Science 241, 105393. 45 dogs, collar + harness. → data/public/
- marcato: Marcato et al. (2023) PLOS ONE 18(6), e0286311. 42 dogs, neck + back + chest,
  CC BY 4.0. → data/public/marcato/
"""

from __future__ import annotations

import hashlib
import json
import sys
import urllib.request
import zipfile
from pathlib import Path

PUBLIC = Path(__file__).resolve().parents[1] / "data" / "public"
DATASETS = {
    "vehkaoja": {
        "id": "vxhx934tbn",
        "version": 4,
        "files": {"Data_description.txt", "DogInfo.csv", "DogMoveData_csv_format.zip"},
        "out": PUBLIC,
    },
    "marcato": {
        "id": "mpph6bmn7g",
        "version": 1,
        "files": {"readme.md", "df_dogs.csv", "df_raw.csv"},
        "out": PUBLIC / "marcato",
    },
}
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


def extract(zip_path: Path, out_dir: Path) -> None:
    with zipfile.ZipFile(zip_path) as zf:
        for member in zf.namelist():
            target = (out_dir / member).resolve()
            if not target.is_relative_to(out_dir.resolve()):  # guard against path traversal
                raise RuntimeError(f"suspicious path in zip: {member}")
        zf.extractall(out_dir)
        print("extracted:", ", ".join(zf.namelist()))


def fetch(name: str) -> int:
    ds = DATASETS[name]
    out: Path = ds["out"]
    out.mkdir(parents=True, exist_ok=True)
    api = (
        f"https://data.mendeley.com/public-api/datasets/{ds['id']}/files"
        f"?folder_id=root&version={ds['version']}"
    )
    with urllib.request.urlopen(urllib.request.Request(api, headers=UA)) as resp:
        files = json.load(resp)

    for meta in files:
        fname = meta["filename"]
        if fname not in ds["files"]:
            continue
        details = meta["content_details"]
        dest = out / fname
        if dest.exists() and sha256(dest) == details["sha256_hash"]:
            print(f"ok (already there): {name}/{fname}")
            continue
        print(f"downloading: {name}/{fname}")
        download(details["download_url"], dest, details["size"])
        if sha256(dest) != details["sha256_hash"]:
            print(f"ERROR: hash mismatch for {fname}", file=sys.stderr)
            return 1
        if dest.suffix == ".zip":
            extract(dest, out)
    return 0


def main() -> int:
    names = sys.argv[1:] or list(DATASETS)
    for name in names:
        if name not in DATASETS:
            print(f"unknown dataset: {name} (choose from {', '.join(DATASETS)})", file=sys.stderr)
            return 2
        if fetch(name):
            return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

# ADR 0012: BLE library for the app: universal_ble (BSD-3), not flutter_blue_plus

- **Status:** accepted
- **Date:** 2026-11-17
- **Affects:** `app/` (Flutter), ADR 0009 (open project now, product later)

## Context

`flutter_blue_plus` is the most popular Flutter BLE plugin and was the default choice. Its
2.x releases use the "FlutterBluePlus License" (v1.6), which:

- requires a **paid commercial license** for any for-profit use or organization;
- forbids relicensing;
- may send **license telemetry at build time** (package name, app name, versions).

This project is MIT and plans to become a product (path B). Depending on a library that
becomes paid exactly when that happens, and that phones home during builds, conflicts with
both goals.

## Decision

Use **universal_ble** (Navideck, BSD-3-Clause): Android, iOS, macOS, Windows, Linux and Web;
scanning with service filters, connect, MTU request, service discovery and notifications,
which is everything the collar needs. BLE access sits behind the app's own `CollarLink`
interface, so the library can be swapped again without touching the rest of the app.

## Alternatives

- **flutter_blue_plus with `License.nonprofit`:** fine for personal use today, but a trap
  for path B and adds build-time telemetry.
- **flutter_reactive_ble (BSD-3):** permissive too, but less active maintenance.

## Consequences

Before adding any dependency, check its license as well as its API: permissive (MIT, BSD,
Apache) only, unless an ADR says otherwise.

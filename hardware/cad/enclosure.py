"""Parametric collar enclosure, prototype v1 (Phase 1): XIAO nRF52840 Sense + 502030 LiPo.

    uv run python enclosure.py            # writes out/*.step, out/*.stl and prints a report

Layout (cross-section, collar runs along X through the strap tunnel):

      lid (1.6) with the orientation arrow, 2 x M2 screws in the end ears
    ┌──────────────────────────────────────────┐
    │ ear │  LiPo 502030 (on foam tape)  │ ear │
    │  ◯  │  XIAO, IMU side down, USB-C → +Y wall (charging slot)
    │     │  floor rails                  │     │
    ├─────┴───────────────────────────────┴─────┤  floor (1.2)
    │      strap tunnel (collar passes here)     │
    └────────────────────────────────────────────┘  skin (1.0)

The XIAO sits at the bottom (closest to the neck, wires to its BAT pads run under it between
the rails); its USB-C faces the +Y long wall, which has a slot for the cable (charge with the collar off the dog). The arrow on the
lid points to +Y: mount the collar with the arrow toward the dog's head (contract 4.2: always
the same orientation). Not waterproof: the sealed TPU-skinned version is Phase 6.
"""

from __future__ import annotations

from dataclasses import dataclass, replace
from pathlib import Path

from build123d import (
    Align,
    Axis,
    Box,
    Compound,
    Cylinder,
    Location,
    Part,
    Polygon,
    Pos,
    extrude,
    export_step,
    export_stl,
    fillet,
)

OUT = Path(__file__).parent / "out"
PETG_G_PER_CM3 = 1.27


@dataclass(frozen=True)
class Params:
    # parts (mm): datasheet values; measure your own parts and adjust if they differ
    xiao_l: float = 21.0  # along Y (USB end at +Y)
    xiao_w: float = 17.8  # along X
    xiao_pcb: float = 1.0
    xiao_top: float = 3.3  # tallest part above the PCB (USB-C receptacle)
    batt_l: float = 30.0  # 502030 LiPo, ~250 mAh, PCM included
    batt_w: float = 20.0
    batt_h: float = 5.2
    foam: float = 0.8  # double-sided foam tape between the XIAO and the battery
    # collar
    strap_w: float = 20.5  # tunnel width: fits collars up to strap_w - 0.5 wide
    strap_t: float = 3.0  # tunnel height: collar thickness + play
    # shell
    wall: float = 1.6
    floor: float = 1.2  # tunnel roof = cavity floor (prints as a bridge)
    skin: float = 1.0  # under the tunnel
    lid: float = 1.6
    lip: float = 1.0  # lid lip depth into the cavity
    fit: float = 0.15  # lid lip clearance per side
    ear: float = 5.0  # screw ear at each end
    rail_h: float = 1.2  # room under the XIAO for the wires soldered to its BAT pads
    corner_r: float = 3.0
    screw_pilot: float = 1.7  # M2 self-tapping
    screw_clear: float = 2.4
    screw_depth: float = 7.0
    usb_w: float = 12.5  # cable plug overmold
    usb_h: float = 6.6

    @property
    def cav_l(self) -> float:
        return max(self.batt_l, self.xiao_w) + 1.0

    @property
    def cav_w(self) -> float:
        return max(self.batt_w, self.xiao_l) + 0.6

    @property
    def stack_h(self) -> float:
        return self.rail_h + self.xiao_pcb + self.xiao_top + self.foam + self.batt_h

    @property
    def cav_h(self) -> float:
        return self.stack_h + self.lip + 0.4  # the lid lip clears the battery

    @property
    def out_l(self) -> float:
        return self.cav_l + 2 * self.wall + 2 * self.ear

    @property
    def out_w(self) -> float:
        return max(self.cav_w, self.strap_w) + 2 * self.wall

    @property
    def z_floor(self) -> float:
        """Top of the cavity floor."""
        return self.skin + self.strap_t + self.floor

    @property
    def base_h(self) -> float:
        return self.z_floor + self.cav_h

    @property
    def screw_x(self) -> float:
        return self.cav_l / 2 + self.wall + self.ear / 2


def _rounded_box(length: float, width: float, height: float, r: float) -> Part:
    b = Box(length, width, height, align=(Align.CENTER, Align.CENTER, Align.MIN))
    return fillet(b.edges().filter_by(Axis.Z), radius=r)


def base(p: Params) -> Part:
    body = _rounded_box(p.out_l, p.out_w, p.base_h, p.corner_r)
    # strap tunnel, open at both ends (along X)
    body -= Pos(0, 0, p.skin) * Box(
        p.out_l + 2, p.strap_w, p.strap_t, align=(Align.CENTER, Align.CENTER, Align.MIN)
    )
    # cavity
    body -= Pos(0, 0, p.z_floor) * _rounded_box(p.cav_l, p.cav_w, p.cav_h + 1, 1.0)
    # rails under the XIAO's long edges (wires from the battery pads pass between them)
    for sx in (-1, 1):
        x = sx * (p.xiao_w / 2 - 1.0)
        body += Pos(x, 0, p.z_floor) * Box(
            1.2, p.cav_w, p.rail_h, align=(Align.CENTER, Align.CENTER, Align.MIN)
        )
    # USB-C slot in the +Y wall, centered on the XIAO's receptacle
    usb_z = p.z_floor + p.rail_h + p.xiao_pcb + p.xiao_top / 2
    z0 = max(p.z_floor, usb_z - p.usb_h / 2)
    # through the whole +Y side, which is thicker than `wall` when the tunnel is wider
    # than the cavity (25 mm collars)
    body -= Pos(0, p.cav_w / 2 - 0.5, z0) * Box(
        p.usb_w, p.out_w, p.usb_h, align=(Align.CENTER, Align.MIN, Align.MIN)
    )
    # screw pilots in the ears
    for sx in (-1, 1):
        body -= Pos(sx * p.screw_x, 0, p.base_h - p.screw_depth) * Cylinder(
            p.screw_pilot / 2, p.screw_depth + 1, align=(Align.CENTER, Align.CENTER, Align.MIN)
        )
    return body


def _arrow(length: float, width: float) -> Part:
    """Arrow pointing to +Y, as a 0.6 mm deep engraving tool."""
    h, s = length * 0.4, width * 0.35
    pts = [
        (0, length / 2),
        (width / 2, length / 2 - h),
        (s / 2, length / 2 - h),
        (s / 2, -length / 2),
        (-s / 2, -length / 2),
        (-s / 2, length / 2 - h),
        (-width / 2, length / 2 - h),
    ]
    return extrude(Polygon(*pts, align=None), amount=1.0)


def lid(p: Params) -> Part:
    """Printed upside down (outer face on the bed) so the arrow engraving is on the bed side."""
    plate = _rounded_box(p.out_l, p.out_w, p.lid, p.corner_r)
    il, iw = p.cav_l - 2 * p.fit, p.cav_w - 2 * p.fit
    lip = _rounded_box(il, iw, p.lip, 0.85) - _rounded_box(il - 2.0, iw - 2.0, p.lip, 0.5)
    part = plate + Pos(0, 0, -p.lip) * lip
    for sx in (-1, 1):
        part -= Pos(sx * p.screw_x, 0, -1) * Cylinder(
            p.screw_clear / 2, p.lid + 2, align=(Align.CENTER, Align.CENTER, Align.MIN)
        )
    part -= Pos(0, 0, p.lid - 0.6) * _arrow(min(p.cav_w - 4, 16), 10)
    return part


def check_fit(p: Params, b: Part, l: Part) -> None:
    """Interference checks with the parts modeled as boxes; raises if anything collides."""
    lid_on = l.moved(Location((0, 0, p.base_h)))
    zb = p.z_floor + p.rail_h  # XIAO underside
    parts = {
        "XIAO": Pos(0, (p.cav_w - p.xiao_l) / 2 - 0.05, zb)
        * Box(p.xiao_w, p.xiao_l, p.xiao_pcb + p.xiao_top, align=(Align.CENTER, Align.CENTER, Align.MIN)),
        "battery": Pos(0, 0, zb + p.xiao_pcb + p.xiao_top + p.foam)
        * Box(p.batt_l, p.batt_w, p.batt_h, align=(Align.CENTER, Align.CENTER, Align.MIN)),
        "collar strap": Pos(0, 0, p.skin + 0.1)
        * Box(p.out_l + 10, p.strap_w - 0.5, p.strap_t - 0.4, align=(Align.CENTER, Align.CENTER, Align.MIN)),
        "USB-C plug": Pos(0, p.cav_w / 2 + 6, zb + p.xiao_pcb + p.xiao_top / 2)
        * Box(12.0, 12.0, 6.2, align=(Align.CENTER, Align.CENTER, Align.CENTER)),
    }
    for name, box in parts.items():
        for shell_name, shell in (("base", b), ("lid", lid_on)):
            v = (box & shell).volume
            if v > 1e-3:
                raise SystemExit(f"{name} collides with the {shell_name}: {v:.2f} mm³")
    if not (b.is_valid and l.is_valid):
        raise SystemExit("invalid solid")


def report(p: Params, b: Part, l: Part) -> str:
    vol = (b.volume + l.volume) / 1000  # cm³
    shell_g = vol * PETG_G_PER_CM3 * 0.8  # ~0.8 of solid with typical walls/infill on thin parts
    electronics_g = 3.0 + 5.5  # XIAO + 502030 cell (datasheet typicals)
    total = shell_g + electronics_g + 0.5  # screws, tape
    return (
        f"strap {p.strap_w - 0.5:.0f} mm × {p.strap_t:.1f} mm | outer "
        f"{p.out_l:.1f} × {p.out_w:.1f} × {p.base_h + p.lid:.1f} mm | shell ≈ {shell_g:.1f} g, "
        f"total ≈ {total:.0f} g → < 3% of body weight for dogs ≥ {total / 0.03 / 1000:.1f} kg"
    )


def main() -> None:
    OUT.mkdir(exist_ok=True)
    variants = {"16mm": 16.5, "20mm": 20.5, "25mm": 25.5}
    for name, w in variants.items():
        p = replace(Params(), strap_w=w)
        b, l = base(p), lid(p)
        check_fit(p, b, l)
        export_stl(b, str(OUT / f"base_strap{name}.stl"))
        print(report(p, b, l))
        if name == "20mm":
            export_stl(l.rotate(Axis.X, 180), str(OUT / "lid.stl"))
            assembly = Compound(
                children=[b, l.moved(Location((0, 0, p.base_h)))], label="collar_enclosure_v1"
            )
            export_step(assembly, str(OUT / "enclosure_v1_strap20mm.step"))
    # the lid is the same for every strap width only while the cavity sets the outer width
    p25 = replace(Params(), strap_w=25.5)
    if p25.out_w != Params().out_w:
        export_stl(lid(p25).rotate(Axis.X, 180), str(OUT / "lid_strap25mm.stl"))
    print(f"fit checks passed; files in {OUT}")


if __name__ == "__main__":
    main()

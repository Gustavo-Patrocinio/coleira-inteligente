"""Line drawing of the enclosure (exploded base + lid, hidden lines dotted)
→ docs/images/enclosure_v1.png.

    cd hardware/cad && uv run --with matplotlib python render_preview.py
"""

from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
import numpy as np  # noqa: E402
from build123d import Axis, Compound, Location  # noqa: E402

from enclosure import Params, base, lid  # noqa: E402

OUT = Path(__file__).parents[2] / "docs" / "images" / "enclosure_v1.png"


def edges_xy(edges) -> list[np.ndarray]:
    return [np.array([(v.X, v.Y) for v in e.positions(np.linspace(0, 1, 24))]) for e in edges]


def main() -> None:
    p = Params()
    b = base(p)
    lid_up = lid(p).moved(Location((0, 0, p.base_h + 14)))  # exploded
    fig, axes = plt.subplots(1, 2, figsize=(11, 5), dpi=130)
    views = [
        ("top-front: lid with the arrow (to the head), USB-C slot", Compound(children=[b, lid_up]), (90, -120, 110)),
        ("bottom: strap tunnel for the collar", b.rotate(Axis.X, 180), (90, -120, 110)),
    ]
    for ax, (title, shape, eye) in zip(axes, views):
        visible, hidden = shape.project_to_viewport(eye)
        for pts in edges_xy(hidden):
            ax.plot(pts[:, 0], pts[:, 1], color="0.75", lw=0.5, ls=(0, (1, 1.5)))
        for pts in edges_xy(visible):
            ax.plot(pts[:, 0], pts[:, 1], color="0.1", lw=0.9)
        ax.set_aspect("equal")
        ax.set_axis_off()
        ax.set_title(title, fontsize=9)
    fig.suptitle(
        f"Collar enclosure v1 (20 mm collar): {p.out_l:.0f} × {p.out_w:.0f} × {p.base_h + p.lid:.0f} mm",
        fontsize=11,
    )
    fig.tight_layout()
    fig.savefig(OUT)
    print(OUT)


if __name__ == "__main__":
    main()

"""Verify that a generated support archive contains the release HUD artwork."""

import sys
from pathlib import Path
from zipfile import ZipFile


def verify(archive_path):
    source = Path(__file__).resolve().parents[1] / "mm/assets/custom/controller-hud"
    expected = (
        "project-restoration.png",
        "restoration-zr.png",
        "wind-a.png",
        "wind-b.png",
        "wind-x.png",
        "wind-y.png",
        "wind-zl.png",
        "wind-zr.png",
        "wind-r.png",
        "CREDITS.txt",
    )
    with ZipFile(archive_path) as archive:
        for name in expected:
            asset = source / name
            if archive.read(f"controller-hud/{name}") != asset.read_bytes():
                raise SystemExit(f"HUD asset differs from source: {name}")
        extra = set(archive.namelist()) - {f"controller-hud/{name}" for name in expected}
        if any(name.startswith("controller-hud/") and not name.endswith("/") for name in extra):
            raise SystemExit("Unexpected HUD artwork in the support archive")


if __name__ == "__main__":
    verify(sys.argv[1])
    print("Verified bundled Controller HUD artwork and credits")

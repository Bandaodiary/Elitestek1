"""Self-contained assertions for the case-1 golden model."""

from __future__ import annotations

import sys
from pathlib import Path

import numpy as np


THIS_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(THIS_DIR))

from style_pipeline import (  # noqa: E402
    demosaic_rggb10_bilinear,
    raw10_pack,
    raw10_unpack,
    rgb8_to_rggb10,
    round_shift_away_from_zero,
    tiny_style_infer,
)


def run() -> None:
    rng = np.random.default_rng(20260824)
    raw = rng.integers(0, 1024, size=400, dtype=np.uint16)
    assert np.array_equal(raw, raw10_unpack(raw10_pack(raw)))

    values = np.array([-9, -8, -7, -1, 0, 1, 7, 8, 9], dtype=np.int64)
    observed = round_shift_away_from_zero(values, 3)
    expected = np.array([-1, -1, -1, 0, 0, 0, 1, 1, 1], dtype=np.int64)
    assert np.array_equal(observed, expected), (observed, expected)

    # Constant fields must survive Bayer sampling/demosaic in the valid
    # interior.  A one-pixel border is intentionally excluded because simple
    # raw-sample replication is not colour-plane-aware at the frame boundary.
    constant = np.empty((12, 16, 3), dtype=np.uint8)
    constant[..., 0] = 40
    constant[..., 1] = 100
    constant[..., 2] = 220
    reconstructed = demosaic_rggb10_bilinear(rgb8_to_rggb10(constant))
    assert np.array_equal(constant[1:-1, 1:-1], reconstructed[1:-1, 1:-1])

    styled, layers = tiny_style_infer(constant)
    assert styled.shape == (8, 12, 3)
    assert layers["conv1"].shape == (10, 14, 3)
    assert layers["depthwise"].shape == (8, 12, 3)
    # The colour-expansion pointwise layer keeps gray constant fields stable
    # because every row of its matrix sums to eight and uses shift three.
    gray = np.full((12, 16, 3), 91, dtype=np.uint8)
    gray_out, _ = tiny_style_infer(gray)
    assert np.all(gray_out == 91)

    print("GOLDEN_UNIT_TESTS_PASS")


if __name__ == "__main__":
    run()

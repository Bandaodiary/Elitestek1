"""Check the frozen native stage-0 finite-window golden used by the RTL gate.

The RTL preflight intentionally keeps the expected words as constants so that
the simulator has no Python/runtime dependency.  This companion test rebuilds
the first 1, 2, 4, 8, or 16 first-row output pixels from the trained arena and
catches a stale constant if the artifact or the signed-s8 source pattern is
replaced.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

import numpy as np


HERE = Path(__file__).resolve()
CASE_ROOT = HERE.parents[1]
MODEL_ROOT = CASE_ROOT / "model"
if str(MODEL_ROOT) not in sys.path:
    sys.path.insert(0, str(MODEL_ROOT))

from microstyle_quant import _integer_conv, _read_layer_arrays  # noqa: E402


EXPECTED_GROUP0 = (
    0x0E09000000320005,
    0x19000000003A000F,
    0x250000070041001B,
    0x36000028003F0015,
    0x0300011800000011,
    0x1100601700002103,
    0x0000000A05000000,
    0x081100002F200F00,
    0x1206000000360009,
    0x1F000000003D0015,
    0x2B00000C00440021,
    0x2000002F0032001C,
    0x19002D0F0000001E,
    0x00001E0C00000A00,
    0x0213000C17000000,
    0x160300031F14001C,
)
EXPECTED_GROUP1 = (
    0x0000000000190006,
    0x0000000000110000,
    0x0000000001070200,
    0x000000001A001A00,
    0x0000000014002600,
    0x0000000017000000,
    0x0000000024000000,
    0x0000000000112A10,
    0x0000000000170001,
    0x00000000000C0000,
    0x0000000006020800,
    0x0000000030011200,
    0x000000000B003900,
    0x0000000024000000,
    0x0000000001002A0B,
    0x0000000000150008,
)


def source_frame(width: int = 640, height: int = 480) -> np.ndarray:
    yy, xx = np.indices((height, width))
    value = np.empty((height, width, 3), dtype=np.int8)
    for channel in range(3):
        value[:, :, channel] = (
            (17 * xx + 31 * yy + 53 * channel + 11) & 255
        ) - 128
    return value


def check_rtl_constants(text: str) -> None:
    """Fail closed if the actual simulator constants diverge from this oracle.

    This intentionally recognizes only the two finite case tables used by
    this testbench, not arbitrary SystemVerilog expressions.
    """
    for group, expected in enumerate((EXPECTED_GROUP0, EXPECTED_GROUP1)):
        first = re.findall(
            rf"localparam\s+logic\s+\[63:0\]\s+EXPECTED_GROUP{group}\s*=\s*64'h([0-9a-fA-F_]+)\s*;", text
        )
        table = re.findall(
            rf"function\s+automatic\s+logic\s+\[63:0\]\s+expected_group{group}_fn\b(.*?)endfunction",
            text, flags=re.S,
        )
        if len(first) != 1 or len(table) != 1:
            raise AssertionError(f"RTL group {group}: missing or duplicate constant table")
        entries = re.findall(
            rf"\b(\d+)\s*:\s*expected_group{group}_fn\s*=\s*(EXPECTED_GROUP{group}|64'h[0-9a-fA-F_]+)\s*;",
            table[0],
        )
        if len(entries) != 16 or [int(i) for i, _ in entries] != list(range(16)):
            raise AssertionError(f"RTL group {group}: expected exactly indices 0..15")
        actual = tuple(
            int(first[0].replace('_', ''), 16) if value == f"EXPECTED_GROUP{group}"
            else int(value.split("'h")[1].replace('_', ''), 16)
            for _, value in entries
        )
        if actual != expected:
            raise AssertionError(f"RTL group {group}: constants differ from Python oracle")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--artifact",
        type=Path,
        default=CASE_ROOT / "model" / "microstyle24_starry_functional",
    )
    parser.add_argument(
        "--pixels",
        type=int,
        choices=(1, 2, 4, 8, 16),
        default=4,
        help="number of first-row stage-0 pixels to check (1, 2, 4, 8, or 16)",
    )
    args = parser.parse_args()

    rtl_test = CASE_ROOT / "sim" / "tb_c1_r1_native_first_window_engine_preflight.sv"
    check_rtl_constants(rtl_test.read_text(encoding="utf-8"))

    manifest = json.loads((args.artifact / "manifest.json").read_text())
    arena = (args.artifact / manifest["parameter_file"]).read_bytes()
    row = next(
        item for item in manifest["quantized_layers"] if item["name"] == "encoder1.conv3x3_s2"
    )
    weight, bias, multiplier, shift = _read_layer_arrays(arena, row)
    result = _integer_conv(
        source_frame(),
        weight,
        bias,
        multiplier,
        shift,
        stride=2,
        groups=1,
        activation=1,
    )

    got0 = []
    got1 = []
    for pixel in range(args.pixels):
        got0.append(int.from_bytes(result[0, pixel, 0:8].tobytes(), "little"))
        got1.append(int.from_bytes(result[0, pixel, 8:12].tobytes(), "little"))
    if (
        tuple(got0) != EXPECTED_GROUP0[: args.pixels]
        or tuple(got1) != EXPECTED_GROUP1[: args.pixels]
    ):
        raise AssertionError(
            f"native stage-0 golden mismatch pixels={args.pixels}: "
            f"group0={got0!r} group1={got1!r}"
        )

    print(
        "C1_NATIVE_STAGE0_WINDOW_GOLDEN_PASS "
        f"frame=640x480 pixels={args.pixels} groups=2 "
        "rtl_constants=32 "
        f"group0_first={got0[0]:016x} group1_first={got1[0]:016x}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

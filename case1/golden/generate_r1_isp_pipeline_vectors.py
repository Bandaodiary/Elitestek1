"""Generate end-to-end bit-exact vectors for ``c1_r1_isp_pipeline``.

Expected pixels are produced by directly composing the normative functions in
``r1_isp.py``: BLC, valid-crop Debayer, AWB, CCM, and Gamma.  Resize is
intentionally absent because the RTL pipeline under test ends at RGB888.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np

from r1_isp import (
    BAYER_PATTERN_CODES,
    BAYER_PATTERNS,
    apply_awb_q2_14,
    apply_ccm_q3_13,
    apply_gamma_u10_to_u8,
    black_level_correct_raw10,
    demosaic_bilinear_valid_raw10,
)


WIDTH = 10
HEIGHT = 8
FRAME_COUNT = 16
INPUT_PIXELS_PER_FRAME = WIDTH * HEIGHT
OUTPUT_PIXELS_PER_FRAME = (WIDTH - 2) * (HEIGHT - 2)


def _raw_frame(case_index: int) -> np.ndarray:
    yy, xx = np.indices((HEIGHT, WIDTH), dtype=np.int64)
    raw = (
        (xx * (67 + case_index * 2) + yy * (131 + case_index * 4) +
         case_index * 53)
        ^ (xx << (case_index % 5))
        ^ (yy << ((case_index + 2) % 6))
    ) & 1023
    # Pin both sensor-domain extrema and values around representative black
    # levels so subtraction clamp and downstream saturation are unavoidable.
    raw[0, 0] = 0
    raw[0, -1] = 1023
    raw[-1, 0] = 1023
    raw[-1, -1] = 0
    raw[1, 1] = case_index
    raw[2, 2] = 1023 - case_index
    raw[3, 4] = 31
    raw[4, 5] = 1000
    return raw.astype(np.uint16)


def _configuration(case_index: int) -> tuple[
    tuple[int, int, int, int],
    tuple[int, int, int],
    tuple[int, ...],
    tuple[int, int, int],
]:
    black = (
        7 + case_index,
        31 + 2 * case_index,
        79 + 3 * case_index,
        173 + 5 * case_index,
    )
    profile = case_index % 4
    if profile == 0:
        gains = (16384, 16384, 16384)
        ccm = (8192, 0, 0, 0, 8192, 0, 0, 0, 8192)
        offsets = (0, 0, 0)
    elif profile == 1:
        gains = (24576, 12288, 32768)
        ccm = (
            10000, -1200, 500,
            -900, 9000, 700,
            400, -1600, 11000,
        )
        offsets = (4096, -8192, 16384)
    elif profile == 2:
        gains = (65535, 65535, 65535)
        ccm = (
            32767, 32767, 32767,
            -32768, -32768, -32768,
            32767, -32768, 32767,
        )
        offsets = ((1 << 31) - 1, -(1 << 31), 0)
    else:
        gains = (8192, 20000, 50000)
        ccm = (
            8192, 4096, -2048,
            -4096, 10000, 4096,
            2048, -8192, 16000,
        )
        offsets = (-10 << 13, 33 << 13, -50 << 13)
    return black, gains, ccm, offsets


def _pack_config(
    pattern_code: int,
    roi_x: int,
    roi_y: int,
    black: tuple[int, int, int, int],
    gains: tuple[int, int, int],
    ccm: tuple[int, ...],
    offsets: tuple[int, int, int],
) -> int:
    packed = pattern_code | (roi_x << 2) | (roi_y << 3)
    shift = 4
    for value in black:
        packed |= (value & 0x3FF) << shift
        shift += 10
    for value in gains:
        packed |= (value & 0xFFFF) << shift
        shift += 16
    for value in ccm:
        packed |= (value & 0xFFFF) << shift
        shift += 16
    for value in offsets:
        packed |= (value & 0xFFFFFFFF) << shift
        shift += 32
    if shift != 332:
        raise AssertionError(f"configuration packing ended at bit {shift}")
    return packed


def _pack_expected(rgb: np.ndarray) -> list[int]:
    records: list[int] = []
    out_height, out_width, channels = rgb.shape
    if (out_height, out_width, channels) != (HEIGHT - 2, WIDTH - 2, 3):
        raise AssertionError(f"unexpected RGB output shape {rgb.shape}")
    for oy in range(out_height):
        for ox in range(out_width):
            x = ox + 1
            y = oy + 1
            r, g, b = (int(v) for v in rgb[oy, ox])
            rgb24 = (r << 16) | (g << 8) | b
            sof = int(ox == 0 and oy == 0)
            eol = int(ox == out_width - 1)
            eof = int(eol and oy == out_height - 1)
            records.append(
                rgb24 | (x << 24) | (y << 28) |
                (sof << 31) | (eol << 32) | (eof << 33)
            )
    return records


def generate(output_dir: Path, seed: int) -> dict[str, object]:
    # The seed is recorded for reproducibility even though the frame formula
    # is deterministic; it also decorrelates the shared non-monotonic LUT.
    rng = np.random.default_rng(seed)
    address = np.arange(1024, dtype=np.int64)
    gamma = ((address * 73) ^ (address >> 2) ^
             rng.integers(0, 256, size=1024, dtype=np.int64)) & 255
    gamma[0] = 0
    gamma[1] = 0x81
    gamma[511] = 0x5A
    gamma[512] = 0xA5
    gamma[1022] = 0x7E
    gamma[1023] = 0xFF
    gamma = gamma.astype(np.uint8)

    raw_values: list[int] = []
    configs: list[int] = []
    expected: list[int] = []
    frame_records: list[dict[str, object]] = []
    coverage: set[tuple[str, int, int]] = set()
    ccm_zero_count = 0
    ccm_max_count = 0
    non_identity_count = 0

    case_index = 0
    for pattern in BAYER_PATTERNS:
        for roi_y in range(2):
            for roi_x in range(2):
                coverage.add((pattern, roi_x, roi_y))
                raw = _raw_frame(case_index)
                black, gains, ccm, offsets = _configuration(case_index)

                # Direct normative R1 Golden composition, intentionally no
                # resize call and no arithmetic duplicated in this generator.
                blc = black_level_correct_raw10(
                    raw, black, roi_x, roi_y, pattern
                )
                debayer = demosaic_bilinear_valid_raw10(
                    blc, pattern, roi_x, roi_y
                )
                awb = apply_awb_q2_14(debayer, gains)
                linear = apply_ccm_q3_13(awb, ccm, offsets)
                rgb8 = apply_gamma_u10_to_u8(linear, gamma)

                ccm_zero_count += int(np.count_nonzero(linear == 0))
                ccm_max_count += int(np.count_nonzero(linear == 1023))
                identity = (
                    gains == (16384, 16384, 16384) and
                    ccm == (8192, 0, 0, 0, 8192, 0, 0, 0, 8192) and
                    offsets == (0, 0, 0)
                )
                non_identity_count += int(not identity)

                raw_offset = len(raw_values)
                output_offset = len(expected)
                raw_values.extend(int(v) for v in raw.reshape(-1))
                expected.extend(_pack_expected(rgb8))
                configs.append(_pack_config(
                    BAYER_PATTERN_CODES[pattern], roi_x, roi_y,
                    black, gains, ccm, offsets
                ))
                frame_records.append({
                    "index": case_index,
                    "pattern": pattern,
                    "pattern_code": BAYER_PATTERN_CODES[pattern],
                    "roi_x_parity": roi_x,
                    "roi_y_parity": roi_y,
                    "black_r_gr_gb_b": list(black),
                    "awb_q2_14": list(gains),
                    "ccm_q3_13": list(ccm),
                    "offset_q13": list(offsets),
                    "raw_offset": raw_offset,
                    "output_offset": output_offset,
                })
                case_index += 1

    if len(coverage) != 16 or case_index != FRAME_COUNT:
        raise AssertionError("four-pattern by four-ROI coverage is incomplete")
    if len(raw_values) != FRAME_COUNT * INPUT_PIXELS_PER_FRAME:
        raise AssertionError("RAW vector count mismatch")
    if len(expected) != FRAME_COUNT * OUTPUT_PIXELS_PER_FRAME:
        raise AssertionError("RGB vector count mismatch")
    if non_identity_count < 12:
        raise AssertionError("non-identity color coverage is insufficient")
    if ccm_zero_count == 0 or ccm_max_count == 0:
        raise AssertionError("CCM lower/upper saturation was not covered")

    output_dir.mkdir(parents=True, exist_ok=True)
    (output_dir / "r1_isp_pipeline_gamma.hex").write_text(
        "".join(f"{int(v):02x}\n" for v in gamma), encoding="ascii"
    )
    (output_dir / "r1_isp_pipeline_raw.hex").write_text(
        "".join(f"{v:03x}\n" for v in raw_values), encoding="ascii"
    )
    (output_dir / "r1_isp_pipeline_config.hex").write_text(
        "".join(f"{v:083x}\n" for v in configs), encoding="ascii"
    )
    (output_dir / "r1_isp_pipeline_expected.hex").write_text(
        "".join(f"{v:09x}\n" for v in expected), encoding="ascii"
    )

    manifest: dict[str, object] = {
        "seed": seed,
        "width": WIDTH,
        "height": HEIGHT,
        "frames": FRAME_COUNT,
        "input_pixels": len(raw_values),
        "output_pixels": len(expected),
        "outputs_per_frame": OUTPUT_PIXELS_PER_FRAME,
        "patterns": list(BAYER_PATTERNS),
        "pattern_encoding": BAYER_PATTERN_CODES,
        "roi_combinations": 4,
        "non_identity_frames": non_identity_count,
        "ccm_zero_samples": ccm_zero_count,
        "ccm_max_samples": ccm_max_count,
        "config_bits": 332,
        "expected_record": {
            "rgb888": "bits 23:0, R[23:16] G[15:8] B[7:0]",
            "x": "bits 27:24",
            "y": "bits 30:28",
            "sof": 31,
            "eol": 32,
            "eof": 33,
        },
        "frame_records": frame_records,
    }
    (output_dir / "r1_isp_pipeline_manifest.json").write_text(
        json.dumps(manifest, indent=2) + "\n", encoding="utf-8"
    )
    return manifest


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--seed", type=int, default=20260824)
    args = parser.parse_args()
    manifest = generate(args.output_dir, args.seed)
    print(
        "R1_ISP_PIPELINE_VECTORS_PASS "
        f"frames={manifest['frames']} input={manifest['input_pixels']} "
        f"output={manifest['output_pixels']}"
    )


if __name__ == "__main__":
    main()

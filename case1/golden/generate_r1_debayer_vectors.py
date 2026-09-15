"""Generate bit-exact vectors for ``c1_r1_debayer_bilinear``.

The vector suite covers every original Bayer pattern, every ROI x/y parity,
and three input families: deterministic random RAW10, RGB-derived colour
blocks, and boundary/impulse stress.  Expected pixels come from the R1 integer
Golden in :mod:`r1_isp`; the SystemVerilog testbench does not duplicate the
Debayer arithmetic.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np

from r1_isp import (
    BAYER_PATTERN_CODES,
    BAYER_PATTERNS,
    demosaic_bilinear_valid_raw10,
    rgb8_to_bayer10,
)


WIDTH = 10
HEIGHT = 8
PATTERN_CODES = BAYER_PATTERN_CODES
KINDS = ("random", "colour_blocks", "boundary")


def _colour_blocks(pattern: str, crop_x: int, crop_y: int) -> np.ndarray:
    rgb = np.zeros((HEIGHT, WIDTH, 3), dtype=np.uint8)
    rgb[: HEIGHT // 2, : WIDTH // 2] = (245, 17, 9)
    rgb[: HEIGHT // 2, WIDTH // 2 :] = (11, 237, 35)
    rgb[HEIGHT // 2 :, : WIDTH // 2] = (23, 41, 251)
    rgb[HEIGHT // 2 :, WIDTH // 2 :] = (211, 173, 29)
    rgb[2:6, 3:7] = (73, 149, 221)
    return rgb8_to_bayer10(rgb, pattern, crop_x, crop_y)


def _boundary(case_index: int) -> np.ndarray:
    yy, xx = np.indices((HEIGHT, WIDTH), dtype=np.int64)
    raw = ((xx * 73 + yy * 149 + case_index * 37) ^ (xx << 5) ^ (yy << 7)) & 1023
    raw[0, :] = (np.arange(WIDTH, dtype=np.int64) * 101 + 3) & 1023
    raw[-1, :] = 1023 - ((np.arange(WIDTH, dtype=np.int64) * 67 + 5) & 1023)
    raw[:, 0] = (np.arange(HEIGHT, dtype=np.int64) * 131 + 7) & 1023
    raw[:, -1] = 1023 - ((np.arange(HEIGHT, dtype=np.int64) * 89 + 11) & 1023)
    raw[0, 0] = 0
    raw[0, -1] = 1023
    raw[-1, 0] = 1023
    raw[-1, -1] = 0
    raw[1, 1] = 1023
    raw[1, WIDTH - 2] = 0
    raw[HEIGHT - 2, 1] = 1
    raw[HEIGHT - 2, WIDTH - 2] = 1022
    return raw.astype(np.uint16)


def _pack_expected(rgb: np.ndarray) -> list[int]:
    output: list[int] = []
    out_height, out_width, _ = rgb.shape
    for output_y in range(out_height):
        for output_x in range(out_width):
            x = output_x + 1
            y = output_y + 1
            r, g, b = (int(value) for value in rgb[output_y, output_x])
            rgb30 = (r << 20) | (g << 10) | b
            sof = int(output_x == 0 and output_y == 0)
            eol = int(output_x == out_width - 1)
            eof = int(output_x == out_width - 1 and output_y == out_height - 1)
            record = (
                rgb30
                | (x << 30)
                | (y << 38)
                | (sof << 46)
                | (eol << 47)
                | (eof << 48)
            )
            output.append(record)
    return output


def _write_hex(path: Path, values: list[int], digits: int) -> None:
    path.write_text(
        "".join(f"{value:0{digits}x}\n" for value in values), encoding="ascii"
    )


def generate(output_dir: Path, seed: int) -> dict[str, object]:
    output_dir.mkdir(parents=True, exist_ok=True)
    rng = np.random.default_rng(seed)
    input_values: list[int] = []
    expected_values: list[int] = []
    case_configs: list[int] = []
    case_records: list[dict[str, object]] = []
    coverage: set[tuple[str, int, int]] = set()

    case_index = 0
    for pattern in BAYER_PATTERNS:
        pattern_code = PATTERN_CODES[pattern]
        for crop_y in range(2):
            for crop_x in range(2):
                coverage.add((pattern, crop_x, crop_y))
                for kind_code, kind in enumerate(KINDS):
                    if kind == "random":
                        raw = rng.integers(0, 1024, size=(HEIGHT, WIDTH), dtype=np.uint16)
                    elif kind == "colour_blocks":
                        raw = _colour_blocks(pattern, crop_x, crop_y)
                    else:
                        raw = _boundary(case_index)

                    expected = demosaic_bilinear_valid_raw10(
                        raw, pattern, crop_x, crop_y
                    )
                    if expected.shape != (HEIGHT - 2, WIDTH - 2, 3):
                        raise AssertionError(f"unexpected Debayer shape {expected.shape}")
                    if np.any(expected < 0) or np.any(expected > 1023):
                        raise AssertionError("Golden Debayer output escaped unsigned 10 bit")

                    input_offset = len(input_values)
                    output_offset = len(expected_values)
                    input_values.extend(int(value) for value in raw.reshape(-1))
                    expected_values.extend(_pack_expected(expected))
                    config_word = (
                        pattern_code
                        | (crop_x << 2)
                        | (crop_y << 3)
                        | (kind_code << 4)
                    )
                    case_configs.append(config_word)
                    case_records.append(
                        {
                            "index": case_index,
                            "pattern": pattern,
                            "pattern_code": pattern_code,
                            "crop_x_parity": crop_x,
                            "crop_y_parity": crop_y,
                            "kind": kind,
                            "kind_code": kind_code,
                            "input_offset": input_offset,
                            "output_offset": output_offset,
                        }
                    )
                    case_index += 1

    if len(coverage) != 16:
        raise AssertionError(f"expected 16 Bayer/ROI combinations, got {len(coverage)}")

    expected_cases = 4 * 4 * len(KINDS)
    expected_input_count = expected_cases * WIDTH * HEIGHT
    expected_output_count = expected_cases * (WIDTH - 2) * (HEIGHT - 2)
    if len(case_configs) != expected_cases:
        raise AssertionError("case count mismatch")
    if len(input_values) != expected_input_count:
        raise AssertionError("input vector count mismatch")
    if len(expected_values) != expected_output_count:
        raise AssertionError("expected vector count mismatch")

    _write_hex(output_dir / "r1_debayer_input.hex", input_values, 3)
    _write_hex(output_dir / "r1_debayer_expected.hex", expected_values, 13)
    _write_hex(output_dir / "r1_debayer_cases.hex", case_configs, 2)

    manifest: dict[str, object] = {
        "width": WIDTH,
        "height": HEIGHT,
        "patterns": list(BAYER_PATTERNS),
        "pattern_encoding": PATTERN_CODES,
        "kinds": list(KINDS),
        "seed": seed,
        "cases": len(case_configs),
        "input_pixels": len(input_values),
        "output_pixels": len(expected_values),
        "expected_record": {
            "rgb30": "bits 29:0, R[29:20] G[19:10] B[9:0]",
            "x": "bits 37:30",
            "y": "bits 45:38",
            "sof": 46,
            "eol": 47,
            "eof": 48,
        },
        "case_records": case_records,
    }
    (output_dir / "r1_debayer_manifest.json").write_text(
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
        "R1_DEBAYER_VECTORS_PASS "
        f"cases={manifest['cases']} input={manifest['input_pixels']} "
        f"output={manifest['output_pixels']}"
    )


if __name__ == "__main__":
    main()

"""Generate end-to-end vectors for the one-outstanding R1 resize adapter."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np

from r1_isp import resize_axis_q16, resize_bilinear_q16_u8


DIMENSIONS = (
    (1, 1, 1, 1),       # scalar source and destination
    (1, 5, 9, 3),       # one-pixel source width; Q12 threshold-low side
    (1, 4, 12, 2),      # one-pixel source width; Q12 threshold-high side
    (6, 1, 3, 5),       # one-pixel source height
    (4, 3, 4, 3),       # 1:1
    (8, 6, 4, 3),       # exact 2:1 downsample
    (9, 6, 6, 4),       # exact 3:2 downsample
    (7, 5, 4, 3),       # non-integer downsample
    (4, 3, 8, 6),       # exact 2x upsample, negative phase origin
    (5, 3, 8, 7),       # non-integer upsample
    (2, 3, 5, 1),       # one-pixel destination height
    (17, 13, 11, 7),    # odd sizes and non-integer ratios
)


def _source_image(width: int, height: int, case_index: int) -> np.ndarray:
    yy, xx = np.indices((height, width), dtype=np.int64)
    rgb = np.empty((height, width, 3), dtype=np.uint8)
    rgb[..., 0] = (37 * xx + 19 * yy + 53 * case_index) & 255
    rgb[..., 1] = ((73 * xx) ^ (29 * yy) ^ (17 * case_index)) & 255
    rgb[..., 2] = (11 * xx + 97 * yy + 31 * case_index +
                   ((xx * yy) << 2)) & 255
    rgb[0, 0] = (0, 1, 255)
    rgb[-1, -1] = (255, 0, 127)
    if width > 1:
        rgb[0, 1] = (1, 0, 0)
    if height > 1:
        rgb[1, 0] = (0, 1, 0)
    return rgb


def _axis(phase: int, limit: int) -> tuple[int, int, int, int, int]:
    lower = phase // 65536
    fraction = phase - lower * 65536
    weight1 = min(4096, (fraction + 8) >> 4)
    weight0 = 4096 - weight1
    index0 = max(0, min(limit - 1, lower))
    index1 = max(0, min(limit - 1, lower + 1))
    return index0, index1, weight0, weight1, fraction


def _pack_request(
    out_x: int,
    out_y: int,
    x0: int,
    x1: int,
    y0: int,
    y1: int,
    wx0: int,
    wx1: int,
    wy0: int,
    wy1: int,
    last: int,
) -> int:
    fields = (
        (out_x, 16), (out_y, 16),
        (x0, 16), (x1, 16), (y0, 16), (y1, 16),
        (wx0, 13), (wx1, 13), (wy0, 13), (wy1, 13),
        (last, 1),
    )
    packed = 0
    for value, width in fields:
        packed = (packed << width) | (value & ((1 << width) - 1))
    return packed


def _pack_output(rgb: np.ndarray) -> list[int]:
    height, width, channels = rgb.shape
    if channels != 3:
        raise AssertionError("RGB output must have three channels")
    records: list[int] = []
    for y in range(height):
        for x in range(width):
            r, g, b = (int(v) for v in rgb[y, x])
            rgb24 = (r << 16) | (g << 8) | b
            sof = int(x == 0 and y == 0)
            eol = int(x == width - 1)
            eof = int(eol and y == height - 1)
            records.append(
                rgb24 | (x << 24) | (y << 40) |
                (sof << 56) | (eol << 57) | (eof << 58)
            )
    return records


def generate(output_dir: Path, seed: int) -> dict[str, object]:
    source_pixels: list[int] = []
    requests: list[int] = []
    expected_outputs: list[int] = []
    configs: list[tuple[int, ...]] = []
    case_records: list[dict[str, int]] = []
    weight_low_nibbles: set[int] = set()
    boundary_clamps = 0
    one_dimension_cases = 0
    upsample_cases = 0
    downsample_cases = 0

    for case_index, (win, hin, wout, hout) in enumerate(DIMENSIONS):
        source = _source_image(win, hin, case_index)
        x_step, x_phase0 = resize_axis_q16(win, wout)
        y_step, y_phase0 = resize_axis_q16(hin, hout)
        expected = resize_bilinear_q16_u8(source, wout, hout)

        source_start = len(source_pixels)
        request_start = len(requests)
        output_start = len(expected_outputs)
        source_pixels.extend(
            (int(r) << 16) | (int(g) << 8) | int(b)
            for r, g, b in source.reshape(-1, 3)
        )

        for out_y in range(hout):
            phase_y = y_phase0 + out_y * y_step
            y0, y1, wy0, wy1, y_fraction = _axis(phase_y, hin)
            weight_low_nibbles.add(y_fraction & 15)
            for out_x in range(wout):
                phase_x = x_phase0 + out_x * x_step
                x0, x1, wx0, wx1, x_fraction = _axis(phase_x, win)
                weight_low_nibbles.add(x_fraction & 15)
                unclamped_x0 = phase_x // 65536
                unclamped_y0 = phase_y // 65536
                boundary_clamps += int(
                    unclamped_x0 < 0 or unclamped_x0 + 1 >= win or
                    unclamped_y0 < 0 or unclamped_y0 + 1 >= hin
                )
                last = int(out_x == wout - 1 and out_y == hout - 1)
                requests.append(_pack_request(
                    out_x, out_y, x0, x1, y0, y1,
                    wx0, wx1, wy0, wy1, last
                ))

        expected_outputs.extend(_pack_output(expected))
        source_count = win * hin
        request_count = wout * hout
        configs.append((
            win, hin, wout, hout,
            x_step, y_step, x_phase0, y_phase0,
            source_start, source_count, request_start, request_count,
            output_start, request_count,
        ))
        one_dimension_cases += int(
            win == 1 or hin == 1 or wout == 1 or hout == 1
        )
        upsample_cases += int(wout > win or hout > hin)
        downsample_cases += int(wout < win or hout < hin)
        case_records.append({
            "index": case_index,
            "win": win,
            "hin": hin,
            "wout": wout,
            "hout": hout,
            "x_step_q16": x_step,
            "y_step_q16": y_step,
            "x_phase0_q16": x_phase0,
            "y_phase0_q16": y_phase0,
            "source_start": source_start,
            "request_start": request_start,
            "output_start": output_start,
        })

    if not ({7, 8} <= weight_low_nibbles):
        raise AssertionError("Q16-to-Q12 rounding threshold coverage is missing")
    if boundary_clamps == 0 or one_dimension_cases < 4:
        raise AssertionError("edge-clamp or one-pixel-dimension coverage missing")
    if upsample_cases == 0 or downsample_cases == 0:
        raise AssertionError("both resize directions must be covered")
    if len(requests) != len(expected_outputs):
        raise AssertionError("one output is required for every sample request")

    output_dir.mkdir(parents=True, exist_ok=True)
    (output_dir / "r1_resize_system_source.txt").write_text(
        str(len(source_pixels)) + "\n" +
        "".join(f"{pixel:06x}\n" for pixel in source_pixels),
        encoding="ascii",
    )
    (output_dir / "r1_resize_system_configs.txt").write_text(
        str(len(configs)) + "\n" +
        "\n".join(
            f"{win:04x} {hin:04x} {wout:04x} {hout:04x} "
            f"{x_step & 0xFFFFFFFF:08x} {y_step & 0xFFFFFFFF:08x} "
            f"{x_phase0 & 0xFFFFFFFF:08x} {y_phase0 & 0xFFFFFFFF:08x} "
            f"{source_start:d} {source_count:d} "
            f"{request_start:d} {request_count:d} "
            f"{output_start:d} {output_count:d}"
            for (win, hin, wout, hout, x_step, y_step, x_phase0, y_phase0,
                 source_start, source_count, request_start, request_count,
                 output_start, output_count) in configs
        ) + "\n",
        encoding="ascii",
    )
    (output_dir / "r1_resize_system_requests.txt").write_text(
        str(len(requests)) + "\n" +
        "".join(f"{request:038x}\n" for request in requests),
        encoding="ascii",
    )
    (output_dir / "r1_resize_system_expected.txt").write_text(
        str(len(expected_outputs)) + "\n" +
        "".join(f"{record:015x}\n" for record in expected_outputs),
        encoding="ascii",
    )

    manifest: dict[str, object] = {
        "seed": seed,
        "configs": len(configs),
        "source_pixels": len(source_pixels),
        "requests": len(requests),
        "outputs": len(expected_outputs),
        "one_dimension_cases": one_dimension_cases,
        "upsample_cases": upsample_cases,
        "downsample_cases": downsample_cases,
        "boundary_clamps": boundary_clamps,
        "q12_threshold_low_nibbles": sorted(weight_low_nibbles),
        "cases": case_records,
    }
    (output_dir / "r1_resize_system_manifest.json").write_text(
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
        "R1_RESIZE_SYSTEM_VECTORS_PASS "
        f"configs={manifest['configs']} requests={manifest['requests']} "
        f"outputs={manifest['outputs']}"
    )


if __name__ == "__main__":
    main()

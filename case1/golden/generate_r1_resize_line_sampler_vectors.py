"""Golden vectors for resize_system plus the two-line raster sampler."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np

from r1_isp import resize_axis_q16, resize_bilinear_q16_u8


# Small configurations keep RTL simulation quick while exercising scalar,
# 1:1, integer/non-integer downsample, skipped source rows, and upsample reuse.
DIMENSIONS = (
    (1, 1, 1, 1),
    (5, 4, 5, 4),
    (8, 6, 4, 3),
    (9, 7, 4, 3),
    (4, 3, 8, 7),
    (6, 1, 3, 4),
    (3, 5, 7, 2),
)

# Append without changing the indices used by abort/restart test scenarios.
EXTREME_PHASES = (
    (0x7fffffff, 0x7fffffff, 0x7fffffff, 0x7fffffff),
    (-0x80000000, 0x7fffffff, -0x80000000, 0x7fffffff),
    (0x18000, 0x7fffffff, -0x8000, -0x80000000),
    (-0x80000000, 0, 0x7fffffff, 0x18000),
)


def explicit_phase_rgb(source, width, height, xs, ys, xp, yp):
    """Scalar Python-int reference; no signed32 wrap at intermediate phases."""
    result = np.empty((height, width, 3), dtype=np.uint8)
    for y in range(height):
        py = yp + y * ys
        y0, y1 = axis_pair(py, source.shape[0])
        wy = min(4096, ((py % 65536) + 8) // 16)
        for x in range(width):
            px = xp + x * xs
            x0, x1 = axis_pair(px, source.shape[1])
            wx = min(4096, ((px % 65536) + 8) // 16)
            for c in range(3):
                top = ((4096-wx)*int(source[y0,x0,c]) + wx*int(source[y0,x1,c]) + 2048)//4096
                bottom = ((4096-wx)*int(source[y1,x0,c]) + wx*int(source[y1,x1,c]) + 2048)//4096
                result[y,x,c] = ((4096-wy)*top + wy*bottom + 2048)//4096
    return result


def source_image(width: int, height: int, case_index: int) -> np.ndarray:
    yy, xx = np.indices((height, width), dtype=np.int64)
    rgb = np.empty((height, width, 3), dtype=np.uint8)
    rgb[..., 0] = (41 * xx + 17 * yy + 23 * case_index) & 255
    rgb[..., 1] = ((67 * xx) ^ (31 * yy) ^ (13 * case_index)) & 255
    rgb[..., 2] = (7 * xx + 101 * yy + 47 * case_index + 3 * xx * yy) & 255
    rgb[0, 0] = (0, 255, case_index & 255)
    rgb[-1, -1] = (255, case_index & 255, 1)
    return rgb


def axis_pair(phase_q16: int, limit: int) -> tuple[int, int]:
    lower = phase_q16 // 65536
    return (
        max(0, min(limit - 1, lower)),
        max(0, min(limit - 1, lower + 1)),
    )


def pack_output(rgb: np.ndarray) -> list[int]:
    height, width, channels = rgb.shape
    if channels != 3:
        raise AssertionError("RGB output must have three channels")
    records: list[int] = []
    for y in range(height):
        for x in range(width):
            r, g, b = (int(channel) for channel in rgb[y, x])
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
    expected_outputs: list[int] = []
    configs: list[tuple[int, ...]] = []
    cases: list[dict[str, int]] = []
    reused_vertical_pairs = 0
    skipped_source_rows = 0
    upsample_cases = 0
    downsample_cases = 0

    dimensions = DIMENSIONS + ((8, 7, 5, 4),) * len(EXTREME_PHASES)
    for case_index, (win, hin, wout, hout) in enumerate(dimensions):
        source = source_image(win, hin, case_index)
        expected = resize_bilinear_q16_u8(source, wout, hout)
        x_step, x_phase0 = resize_axis_q16(win, wout)
        y_step, y_phase0 = resize_axis_q16(hin, hout)
        if case_index >= len(DIMENSIONS):
            x_step, y_step, x_phase0, y_phase0 = EXTREME_PHASES[case_index-len(DIMENSIONS)]
            expected = explicit_phase_rgb(source, wout, hout, x_step, y_step, x_phase0, y_phase0)
        elif not np.array_equal(expected, explicit_phase_rgb(source, wout, hout,
                                       x_step, y_step, x_phase0, y_phase0)):
            raise AssertionError("scalar reference differs from normative resize")

        source_start = len(source_pixels)
        output_start = len(expected_outputs)
        source_pixels.extend(
            (int(r) << 16) | (int(g) << 8) | int(b)
            for r, g, b in source.reshape(-1, 3)
        )
        expected_outputs.extend(pack_output(expected))

        previous_pair: tuple[int, int] | None = None
        for out_y in range(hout):
            pair = axis_pair(y_phase0 + out_y * y_step, hin)
            if previous_pair is not None:
                reused_vertical_pairs += int(pair == previous_pair)
                skipped_source_rows += max(0, pair[0] - previous_pair[1] - 1)
            previous_pair = pair

        upsample_cases += int(wout > win or hout > hin)
        downsample_cases += int(wout < win or hout < hin)
        configs.append((
            win, hin, wout, hout,
            x_step, y_step, x_phase0, y_phase0,
            source_start, win * hin,
            output_start, wout * hout,
        ))
        cases.append({
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
            "output_start": output_start,
        })

    if reused_vertical_pairs == 0:
        raise AssertionError("upsample row-reuse coverage is missing")
    if skipped_source_rows == 0:
        raise AssertionError("downsample row-discard coverage is missing")
    if upsample_cases == 0 or downsample_cases == 0:
        raise AssertionError("both resize directions must be covered")

    output_dir.mkdir(parents=True, exist_ok=True)
    (output_dir / "r1_resize_line_sampler_source.txt").write_text(
        str(len(source_pixels)) + "\n" +
        "".join(f"{pixel:06x}\n" for pixel in source_pixels),
        encoding="ascii",
    )
    (output_dir / "r1_resize_line_sampler_configs.txt").write_text(
        str(len(configs)) + "\n" +
        "\n".join(
            f"{win:04x} {hin:04x} {wout:04x} {hout:04x} "
            f"{x_step & 0xFFFFFFFF:08x} {y_step & 0xFFFFFFFF:08x} "
            f"{x_phase0 & 0xFFFFFFFF:08x} {y_phase0 & 0xFFFFFFFF:08x} "
            f"{source_start:d} {source_count:d} "
            f"{output_start:d} {output_count:d}"
            for (win, hin, wout, hout, x_step, y_step, x_phase0, y_phase0,
                 source_start, source_count, output_start, output_count)
            in configs
        ) + "\n",
        encoding="ascii",
    )
    (output_dir / "r1_resize_line_sampler_expected.txt").write_text(
        str(len(expected_outputs)) + "\n" +
        "".join(f"{record:015x}\n" for record in expected_outputs),
        encoding="ascii",
    )

    manifest: dict[str, object] = {
        "seed": seed,
        "configs": len(configs),
        "source_pixels": len(source_pixels),
        "outputs": len(expected_outputs),
        "reused_vertical_pairs": reused_vertical_pairs,
        "skipped_source_rows": skipped_source_rows,
        "upsample_cases": upsample_cases,
        "downsample_cases": downsample_cases,
        "error_checks": 5,
        "cases": cases,
    }
    (output_dir / "r1_resize_line_sampler_manifest.json").write_text(
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
        "R1_RESIZE_LINE_SAMPLER_VECTORS_PASS "
        f"configs={manifest['configs']} outputs={manifest['outputs']} "
        f"reuse={manifest['reused_vertical_pairs']} "
        f"skips={manifest['skipped_source_rows']}"
    )


if __name__ == "__main__":
    main()

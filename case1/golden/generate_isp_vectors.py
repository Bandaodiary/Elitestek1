"""Generate bit-exact RAW10-to-RGB vectors for the portable ISP RTL."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np

from style_pipeline import (
    demosaic_rggb10_bilinear,
    load_rgb,
    resize_nearest_u8,
    rgb8_to_rggb10,
    round_shift_away_from_zero,
    tiny_style_infer,
    write_hex_rgb24,
)


def write_raw10(path: Path, raw10: np.ndarray) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    lines = [f"{int(value):03x}" for value in raw10.reshape(-1)]
    path.write_text("\n".join(lines) + "\n", encoding="ascii")


def r0_color_correct(
    rgb: np.ndarray,
    gains_q8_8: np.ndarray,
    ccm_q3_14: np.ndarray,
    offsets: np.ndarray,
    gamma_knots: np.ndarray,
) -> np.ndarray:
    source = np.asarray(rgb, dtype=np.int64)
    gained = np.clip((source * gains_q8_8.reshape(1, 1, 3) + 128) >> 8, 0, 255)
    accum = np.einsum("...c,oc->...o", gained, ccm_q3_14, dtype=np.int64)
    accum += offsets.reshape(1, 1, 3) << 14
    corrected = np.clip(round_shift_away_from_zero(accum, 14), 0, 255).astype(np.int64)
    segment = corrected >> 4
    fraction = corrected & 15
    base = gamma_knots[segment]
    following = gamma_knots[segment + 1]
    interpolated = ((base << 4) + (following - base) * fraction + 8) >> 4
    return np.clip(interpolated, 0, 255).astype(np.uint8)


def write_config_vectors(
    output_dir: Path,
    black_level: int,
    gains: np.ndarray,
    ccm: np.ndarray,
    offsets: np.ndarray,
    gamma: np.ndarray,
) -> None:
    writes: list[tuple[int, int]] = [(0x00, black_level)]
    writes.extend((0x10 + index, int(value)) for index, value in enumerate(gains))
    writes.extend((0x20 + index, int(value)) for index, value in enumerate(ccm.reshape(-1)))
    writes.extend((0x30 + index, int(value)) for index, value in enumerate(offsets))
    writes.extend((0x50 + index, int(value)) for index, value in enumerate(gamma))
    (output_dir / "isp_config_addr.hex").write_text(
        "\n".join(f"{address:02x}" for address, _ in writes) + "\n", encoding="ascii"
    )
    (output_dir / "isp_config_data.hex").write_text(
        "\n".join(f"{value & 0xFFFFFFFF:08x}" for _, value in writes) + "\n",
        encoding="ascii",
    )


def generate(
    image_path: Path,
    output_dir: Path,
    width: int = 18,
    height: int = 14,
    h_step: int = 2,
    v_step: int = 2,
) -> dict[str, int | str]:
    if width < 3 or height < 3:
        raise ValueError("ISP test image must be at least 3x3")
    rgb = resize_nearest_u8(load_rgb(image_path), width, height)
    raw10 = rgb8_to_rggb10(rgb)
    demosaic = demosaic_rggb10_bilinear(raw10)
    xs = np.arange(1, width - 1, h_step, dtype=np.int64)
    ys = np.arange(1, height - 1, v_step, dtype=np.int64)
    expected = demosaic[ys[:, None], xs[None, :]]
    system_expected, _ = tiny_style_infer(expected)

    config_black_level = 4
    config_gains = np.array([300, 256, 220], dtype=np.int64)
    config_ccm = np.array(
        [[15000, 1000, 384], [-500, 17000, -116], [400, 800, 15184]],
        dtype=np.int64,
    )
    config_offsets = np.array([2, -1, 3], dtype=np.int64)
    config_gamma = np.rint(
        256.0 * np.power(np.arange(17, dtype=np.float64) / 16.0, 0.8)
    ).astype(np.int64)
    configured_raw = np.maximum(raw10.astype(np.int64) - config_black_level, 0).astype(np.uint16)
    configured_demosaic = demosaic_rggb10_bilinear(configured_raw)
    configured_rgb = r0_color_correct(
        configured_demosaic, config_gains, config_ccm, config_offsets, config_gamma
    )
    configured_expected = configured_rgb[ys[:, None], xs[None, :]]

    output_dir.mkdir(parents=True, exist_ok=True)
    write_raw10(output_dir / "isp_input_raw10.hex", raw10)
    write_hex_rgb24(output_dir / "isp_expected_rgb24.hex", expected)
    write_hex_rgb24(output_dir / "system_expected_rgb24.hex", system_expected)
    write_hex_rgb24(output_dir / "isp_config_expected_rgb24.hex", configured_expected)
    write_config_vectors(
        output_dir, config_black_level, config_gains, config_ccm, config_offsets, config_gamma
    )
    manifest: dict[str, int | str] = {
        "source": image_path.name,
        "input_width": width,
        "input_height": height,
        "output_width": int(xs.size),
        "output_height": int(ys.size),
        "system_output_width": int(system_expected.shape[1]),
        "system_output_height": int(system_expected.shape[0]),
        "x_offset": 1,
        "y_offset": 1,
        "h_step": h_step,
        "v_step": v_step,
        "bayer": "RGGB",
        "black_level": 0,
        "awb_gain_q8_8": "256,256,256",
        "ccm_q3_14": "16384,0,0;0,16384,0;0,0,16384",
        "gamma": "identity-17-knot",
        "configured_case_writes": 33,
    }
    (output_dir / "isp_manifest.json").write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    return manifest


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", type=Path, default=Path("assets/images/astronaut.png"))
    parser.add_argument("--output", type=Path, default=Path("sim/vectors"))
    parser.add_argument("--width", type=int, default=18)
    parser.add_argument("--height", type=int, default=14)
    parser.add_argument("--h-step", type=int, default=2)
    parser.add_argument("--v-step", type=int, default=2)
    args = parser.parse_args()
    result = generate(args.image, args.output, args.width, args.height, args.h_step, args.v_step)
    print("ISP_VECTORS_OK", json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

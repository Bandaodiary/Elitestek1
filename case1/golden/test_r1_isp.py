"""Self-contained tests for the bit-exact R1 integer ISP Golden."""

from __future__ import annotations

import sys
from pathlib import Path

import numpy as np


THIS_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(THIS_DIR))

from r1_isp import (  # noqa: E402
    BAYER_PATTERNS,
    R1ISPConfig,
    apply_awb_q2_14,
    apply_ccm_q3_13,
    bayer_phase_indices,
    black_level_correct_raw10,
    identity_gamma_lut,
    resize_axis_q16,
    resize_bilinear_q16_u8,
    rgb8_to_bayer10,
    round_div_away,
    round_shift_away,
    run_r1_isp,
    shifted_bayer_pattern,
)


def _constant_rgb(height: int, width: int, rgb: tuple[int, int, int]) -> np.ndarray:
    image = np.empty((height, width, 3), dtype=np.uint8)
    image[...] = np.asarray(rgb, dtype=np.uint8)
    return image


def _add_phase_offsets(
    raw10: np.ndarray,
    levels: tuple[int, int, int, int],
    pattern: str,
    roi_x: int,
    roi_y: int,
) -> np.ndarray:
    phase = bayer_phase_indices(
        raw10.shape[0], raw10.shape[1], pattern, roi_x, roi_y
    )
    result = raw10.astype(np.int64) + np.asarray(levels, dtype=np.int64)[phase]
    if np.any(result > 1023):
        raise AssertionError("test fixture overflowed RAW10")
    return result.astype(np.uint16)


def _resize_scalar_reference(image: np.ndarray, out_width: int, out_height: int) -> np.ndarray:
    source = np.asarray(image, dtype=np.int64)
    squeeze = source.ndim == 2
    if squeeze:
        source = source[..., None]
    in_height, in_width, channels = source.shape
    x_step, x_phase0 = resize_axis_q16(in_width, out_width)
    y_step, y_phase0 = resize_axis_q16(in_height, out_height)
    output = np.empty((out_height, out_width, channels), dtype=np.uint8)
    for out_y in range(out_height):
        phase_y = y_phase0 + out_y * y_step
        y0 = phase_y // 65536
        fy16 = phase_y - y0 * 65536
        wy1 = min(4096, (fy16 + 8) >> 4)
        wy0 = 4096 - wy1
        y1 = y0 + 1
        y0 = min(max(y0, 0), in_height - 1)
        y1 = min(max(y1, 0), in_height - 1)
        for out_x in range(out_width):
            phase_x = x_phase0 + out_x * x_step
            x0 = phase_x // 65536
            fx16 = phase_x - x0 * 65536
            wx1 = min(4096, (fx16 + 8) >> 4)
            wx0 = 4096 - wx1
            x1 = x0 + 1
            x0 = min(max(x0, 0), in_width - 1)
            x1 = min(max(x1, 0), in_width - 1)
            for channel in range(channels):
                top = (
                    wx0 * int(source[y0, x0, channel])
                    + wx1 * int(source[y0, x1, channel])
                    + 2048
                ) >> 12
                bottom = (
                    wx0 * int(source[y1, x0, channel])
                    + wx1 * int(source[y1, x1, channel])
                    + 2048
                ) >> 12
                value = (wy0 * top + wy1 * bottom + 2048) >> 12
                output[out_y, out_x, channel] = min(max(value, 0), 255)
    return output[..., 0] if squeeze else output


def test_rounding_contract() -> None:
    ratios = {
        (1, 2): 1,
        (-1, 2): -1,
        (3, 2): 2,
        (-3, 2): -2,
        (4, 3): 1,
        (-4, 3): -1,
        (5, 3): 2,
        (-5, 3): -2,
    }
    for (numerator, denominator), expected in ratios.items():
        assert round_div_away(numerator, denominator) == expected
    values = np.asarray([-9, -8, -7, -4, -1, 0, 1, 4, 7, 8, 9], dtype=np.int64)
    expected = np.asarray([-1, -1, -1, -1, 0, 0, 0, 1, 1, 1, 1], dtype=np.int64)
    np.testing.assert_array_equal(round_shift_away(values, 3), expected)


def test_identity_four_patterns_and_roi_parity() -> None:
    source = _constant_rgb(9, 11, (40, 100, 220))
    for pattern in BAYER_PATTERNS:
        observed_shifts: set[str] = set()
        for roi_y in (0, 1):
            for roi_x in (0, 1):
                observed_shifts.add(shifted_bayer_pattern(pattern, roi_x, roi_y))
                raw = rgb8_to_bayer10(source, pattern, roi_x, roi_y)
                config = R1ISPConfig(
                    bayer_pattern=pattern,
                    roi_x=roi_x,
                    roi_y=roi_y,
                )
                output, stages = run_r1_isp(raw, source.shape[1] - 2, source.shape[0] - 2, config)
                np.testing.assert_array_equal(output, source[1:-1, 1:-1])
                assert stages["demosaic_rgb10"].dtype == np.uint16
                assert stages["demosaic_rgb10"].shape == (7, 9, 3)
                assert stages["effective_bayer"] == shifted_bayer_pattern(
                    pattern, roi_x, roi_y
                )
        assert observed_shifts == set(BAYER_PATTERNS)


def test_four_phase_black_level() -> None:
    source = _constant_rgb(8, 10, (30, 60, 90))
    levels = (1, 7, 13, 31)
    for pattern in BAYER_PATTERNS:
        for roi_y in (0, 1):
            for roi_x in (0, 1):
                clean = rgb8_to_bayer10(source, pattern, roi_x, roi_y)
                offset = _add_phase_offsets(clean, levels, pattern, roi_x, roi_y)
                corrected = black_level_correct_raw10(
                    offset, levels, roi_x, roi_y, pattern
                )
                np.testing.assert_array_equal(corrected, clean)
                output, _ = run_r1_isp(
                    offset,
                    source.shape[1] - 2,
                    source.shape[0] - 2,
                    R1ISPConfig(
                        bayer_pattern=pattern,
                        roi_x=roi_x,
                        roi_y=roi_y,
                        black_levels=levels,
                    ),
                )
                np.testing.assert_array_equal(output, source[1:-1, 1:-1])


def test_nonidentity_awb_negative_ccm_and_gamma() -> None:
    source = _constant_rgb(8, 10, (40, 80, 100))
    raw = rgb8_to_bayer10(source, "GBRG", roi_x=1, roi_y=0)
    gamma = np.minimum(255, (np.arange(1024, dtype=np.int64) + 1) >> 1).astype(np.uint8)
    config = R1ISPConfig(
        bayer_pattern="GBRG",
        roi_x=1,
        roi_y=0,
        awb_gain_q2_14=(24576, 8192, 32768),  # 1.5, 0.5, 2.0
        ccm_q3_13=(
            8192,
            -8192,
            0,
            -8192,
            8192,
            0,
            0,
            0,
            8192,
        ),
        gamma_lut=gamma,
    )
    output, stages = run_r1_isp(raw, 8, 6, config)
    np.testing.assert_array_equal(stages["awb_rgb12"], np.full((6, 8, 3), (240, 160, 800)))
    np.testing.assert_array_equal(stages["ccm_rgb10"], np.full((6, 8, 3), (80, 0, 800)))
    np.testing.assert_array_equal(stages["gamma_rgb8"], np.full((6, 8, 3), (40, 0, 255)))
    np.testing.assert_array_equal(output, np.full((6, 8, 3), (40, 0, 255)))


def test_saturation_and_q_format_edges() -> None:
    single = np.ones((1, 1, 3), dtype=np.uint16)
    np.testing.assert_array_equal(
        apply_awb_q2_14(single, (8192, 16384, 24576)),
        np.asarray([[[1, 1, 2]]], dtype=np.uint16),
    )

    ccm_input = np.asarray([[[4095, 4095, 4095]]], dtype=np.uint16)
    saturated = apply_ccm_q3_13(
        ccm_input,
        (
            32767,
            0,
            0,
            -32768,
            0,
            0,
            0,
            0,
            8192,
        ),
    )
    np.testing.assert_array_equal(saturated, np.asarray([[[1023, 0, 1023]]], dtype=np.uint16))

    white = _constant_rgb(7, 9, (255, 255, 255))
    raw = rgb8_to_bayer10(white)
    output, stages = run_r1_isp(
        raw,
        7,
        5,
        R1ISPConfig(
            awb_gain_q2_14=(65535, 65535, 65535),
            ccm_q3_13=(32767, 0, 0, -32768, 0, 0, 0, 0, 8192),
        ),
    )
    assert int(stages["awb_rgb12"].max()) <= 4095
    np.testing.assert_array_equal(output, np.full((5, 7, 3), (255, 0, 255)))

    zero = np.zeros((5, 5), dtype=np.uint16)
    np.testing.assert_array_equal(
        black_level_correct_raw10(zero, (1, 2, 3, 4)), np.zeros_like(zero)
    )


def test_resize_identity_known_values_and_odd_even_sizes() -> None:
    assert resize_axis_q16(2, 4) == (32768, -16384)
    assert resize_axis_q16(3, 2) == (98304, 16384)

    two = np.asarray([[0, 100]], dtype=np.uint8)
    np.testing.assert_array_equal(
        resize_bilinear_q16_u8(two, 4, 1), np.asarray([[0, 25, 75, 100]], dtype=np.uint8)
    )
    three = np.asarray([[0, 100, 200]], dtype=np.uint8)
    np.testing.assert_array_equal(
        resize_bilinear_q16_u8(three, 2, 1), np.asarray([[25, 175]], dtype=np.uint8)
    )

    rng = np.random.default_rng(20260824)
    cases = (
        ((5, 7, 3), 8, 6),   # odd input, even output, negative initial phase
        ((6, 8, 3), 7, 5),   # even input, odd output
        ((7, 6, 3), 9, 4),   # mixed axes and a non-integer ratio
        ((5, 5, 3), 5, 5),   # exact identity
    )
    for shape, out_width, out_height in cases:
        source = rng.integers(0, 256, size=shape, dtype=np.uint8)
        expected = _resize_scalar_reference(source, out_width, out_height)
        observed = resize_bilinear_q16_u8(source, out_width, out_height)
        np.testing.assert_array_equal(observed, expected)
        if (shape[1], shape[0]) == (out_width, out_height):
            np.testing.assert_array_equal(observed, source)


def test_validation_errors() -> None:
    try:
        rgb8_to_bayer10(np.zeros((3, 3, 3), dtype=np.uint8), "INVALID")
    except ValueError:
        pass
    else:
        raise AssertionError("invalid Bayer pattern was accepted")

    bad_lut = identity_gamma_lut().astype(np.int64)
    bad_lut[100] = 256
    raw = rgb8_to_bayer10(_constant_rgb(5, 5, (20, 30, 40)))
    try:
        run_r1_isp(raw, 3, 3, R1ISPConfig(gamma_lut=bad_lut))
    except ValueError:
        pass
    else:
        raise AssertionError("out-of-range Gamma entry was accepted")


def run() -> None:
    tests = (
        test_rounding_contract,
        test_identity_four_patterns_and_roi_parity,
        test_four_phase_black_level,
        test_nonidentity_awb_negative_ccm_and_gamma,
        test_saturation_and_q_format_edges,
        test_resize_identity_known_values_and_odd_even_sizes,
        test_validation_errors,
    )
    for test in tests:
        test()
        print(f"PASS {test.__name__}")
    print(f"R1_ISP_TESTS_PASS count={len(tests)}")


if __name__ == "__main__":
    run()

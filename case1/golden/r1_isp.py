"""Bit-exact integer Golden for the case-1 R1 image-signal pipeline.

The input array is one already-extracted RAW10 ROI. ``roi_x`` and ``roi_y``
are the ROI origin in sensor coordinates; they affect both the Bayer phase and
the four-phase black-level lookup. The first R1 implementation deliberately
uses a valid-crop demosaic: only centres with a complete 3x3 CFA window are
returned. It never replicates a RAW Bayer edge, because doing so would copy a
sample from the wrong colour phase.

Pipeline:

    RAW10 ROI
      -> four-phase BLC
      -> 10-bit valid-crop bilinear Debayer
      -> Q2.14 AWB, clamped to unsigned 12 bit
      -> Q3.13 CCM, clamped to unsigned 10 bit
      -> 1024 x 8 Gamma LUT
      -> centre-aligned Q16.16 bilinear Resize

Every operation is integer-only. Rounding, saturation, tensor order, Bayer
phase and resize phase are explicit so a future RTL implementation can use
this module as a per-pixel oracle.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Final

import numpy as np


Array = np.ndarray
BAYER_PATTERNS: Final[tuple[str, ...]] = ("RGGB", "BGGR", "GRBG", "GBRG")
BAYER_PATTERN_CODES: Final[dict[str, int]] = {
    name: code for code, name in enumerate(BAYER_PATTERNS)
}

_BAYER_TILES: Final[dict[str, tuple[tuple[str, str], tuple[str, str]]]] = {
    "RGGB": (("R", "G"), ("G", "B")),
    "BGGR": (("B", "G"), ("G", "R")),
    "GRBG": (("G", "R"), ("B", "G")),
    "GBRG": (("G", "B"), ("R", "G")),
}
# Canonical black-level phase IDs are 0=R, 1=Gr, 2=Gb, 3=B.  Gr is the
# green site on the same Bayer row as R; Gb is the green site on the same row
# as B.  These tiles deliberately follow the public pattern-code order above.
_BAYER_PHASE_TILES: Final[
    dict[str, tuple[tuple[int, int], tuple[int, int]]]
] = {
    "RGGB": ((0, 1), (2, 3)),
    "BGGR": ((3, 2), (1, 0)),
    "GRBG": ((1, 0), (3, 2)),
    "GBRG": ((2, 3), (0, 1)),
}
_CHANNEL_INDEX: Final[dict[str, int]] = {"R": 0, "G": 1, "B": 2}


def round_div_away(numerator: int, denominator: int) -> int:
    """Round a signed integer ratio to nearest, with ties away from zero."""
    numerator = int(numerator)
    denominator = int(denominator)
    if denominator <= 0:
        raise ValueError("denominator must be positive")
    magnitude, remainder = divmod(abs(numerator), denominator)
    if 2 * remainder >= denominator:
        magnitude += 1
    return -magnitude if numerator < 0 else magnitude


def round_shift_away(values: Array | int, shift: int) -> Array:
    """Signed right shift rounded to nearest, with ties away from zero."""
    shift = int(shift)
    data = np.asarray(values, dtype=np.int64)
    if shift < 0:
        return data << (-shift)
    if shift == 0:
        return data.copy()
    magnitude = np.abs(data)
    rounded = (magnitude + (1 << (shift - 1))) >> shift
    return np.where(data < 0, -rounded, rounded)


def sat_u8(values: Array | int) -> Array:
    return np.clip(np.asarray(values, dtype=np.int64), 0, 255).astype(np.uint8)


def sat_u10(values: Array | int) -> Array:
    return np.clip(np.asarray(values, dtype=np.int64), 0, 1023).astype(np.uint16)


def _validate_pattern(pattern: str) -> str:
    normalized = str(pattern).upper()
    if normalized not in _BAYER_TILES:
        raise ValueError(f"unsupported Bayer pattern {pattern!r}; expected {BAYER_PATTERNS}")
    return normalized


def shifted_bayer_pattern(pattern: str, roi_x: int = 0, roi_y: int = 0) -> str:
    """Return the Bayer pattern seen at an ROI with the given sensor origin."""
    pattern = _validate_pattern(pattern)
    source = _BAYER_TILES[pattern]
    x_phase = int(roi_x) & 1
    y_phase = int(roi_y) & 1
    shifted = tuple(
        tuple(source[(row + y_phase) & 1][(column + x_phase) & 1] for column in range(2))
        for row in range(2)
    )
    encoded = "".join(shifted[0] + shifted[1])
    if encoded not in _BAYER_TILES:
        raise AssertionError(f"invalid shifted Bayer tile {encoded}")
    return encoded


def identity_gamma_lut() -> Array:
    """Return the normative linear 10-to-8-bit Gamma table."""
    address = np.arange(1024, dtype=np.int64)
    return np.minimum(255, (address + 2) >> 2).astype(np.uint8)


@dataclass(frozen=True)
class R1ISPConfig:
    """Static parameters used for one complete frame.

    ``black_levels`` is ordered by canonical colour phase as
    ``(R, Gr, Gb, B)``.  Gr is the green site on the R row and Gb the green
    site on the B row.  CCM coefficients are flattened row-major in
    output-channel/input-channel order. CCM offsets are already in the same
    Q3.13 product domain as the matrix accumulation.
    """

    bayer_pattern: str = "RGGB"
    roi_x: int = 0
    roi_y: int = 0
    black_levels: tuple[int, int, int, int] = (0, 0, 0, 0)
    awb_gain_q2_14: tuple[int, int, int] = (16384, 16384, 16384)
    ccm_q3_13: tuple[int, int, int, int, int, int, int, int, int] = (
        8192,
        0,
        0,
        0,
        8192,
        0,
        0,
        0,
        8192,
    )
    ccm_offset_q13: tuple[int, int, int] = (0, 0, 0)
    gamma_lut: Array = field(default_factory=identity_gamma_lut, compare=False, repr=False)


def _require_raw10(raw10: Array) -> Array:
    raw = np.asarray(raw10)
    if raw.ndim != 2:
        raise ValueError("RAW10 ROI must be a two-dimensional array")
    if raw.shape[0] < 3 or raw.shape[1] < 3:
        raise ValueError("valid-crop Debayer requires an ROI of at least 3x3")
    if not np.issubdtype(raw.dtype, np.integer):
        raise TypeError("RAW10 ROI must contain integers")
    values = raw.astype(np.int64, copy=False)
    if np.any(values < 0) or np.any(values > 1023):
        raise ValueError("RAW10 sample outside 0..1023")
    return values


def bayer_phase_indices(
    height: int,
    width: int,
    pattern: str = "RGGB",
    roi_x: int = 0,
    roi_y: int = 0,
) -> Array:
    """Return canonical ``R/Gr/Gb/B`` phase IDs for an ROI-local raster."""
    height = int(height)
    width = int(width)
    if height <= 0 or width <= 0:
        raise ValueError("Bayer phase dimensions must be positive")
    effective = shifted_bayer_pattern(pattern, roi_x, roi_y)
    phase_tile = np.asarray(_BAYER_PHASE_TILES[effective], dtype=np.int64)
    yy, xx = np.indices((height, width), dtype=np.int64)
    return phase_tile[yy & 1, xx & 1]


def black_level_correct_raw10(
    raw10: Array,
    black_levels: tuple[int, int, int, int] | Array,
    roi_x: int = 0,
    roi_y: int = 0,
    pattern: str = "RGGB",
) -> Array:
    """Subtract canonical ``(R,Gr,Gb,B)`` black levels and saturate to u10."""
    raw = _require_raw10(raw10)
    levels = np.asarray(black_levels, dtype=np.int64).reshape(-1)
    if levels.shape != (4,) or np.any(levels < 0) or np.any(levels > 1023):
        raise ValueError("black_levels must contain four values in 0..1023")
    phase = bayer_phase_indices(raw.shape[0], raw.shape[1], pattern, roi_x, roi_y)
    return sat_u10(raw - levels[phase])


def rgb8_to_bayer10(
    rgb: Array, pattern: str = "RGGB", roi_x: int = 0, roi_y: int = 0
) -> Array:
    """Create an exact RAW10 Bayer test image from RGB888 code values."""
    image = np.asarray(rgb)
    if image.ndim != 3 or image.shape[2] != 3:
        raise ValueError("RGB input must have shape HxWx3")
    if not np.issubdtype(image.dtype, np.integer):
        raise TypeError("RGB input must contain integers")
    values = image.astype(np.int64, copy=False)
    if np.any(values < 0) or np.any(values > 255):
        raise ValueError("RGB sample outside 0..255")
    effective = shifted_bayer_pattern(pattern, roi_x, roi_y)
    tile = _BAYER_TILES[effective]
    yy, xx = np.indices(image.shape[:2], dtype=np.int64)
    channel = np.empty(image.shape[:2], dtype=np.int64)
    for row in range(2):
        for column in range(2):
            mask = ((yy & 1) == row) & ((xx & 1) == column)
            channel[mask] = _CHANNEL_INDEX[tile[row][column]]
    sampled = np.take_along_axis(values, channel[..., None], axis=2)[..., 0]
    return (sampled << 2).astype(np.uint16)


def _avg2(a: Array, b: Array) -> Array:
    return (a.astype(np.int64) + b.astype(np.int64) + 1) >> 1


def _avg4(a: Array, b: Array, c: Array, d: Array) -> Array:
    return (
        a.astype(np.int64)
        + b.astype(np.int64)
        + c.astype(np.int64)
        + d.astype(np.int64)
        + 2
    ) >> 2


def demosaic_bilinear_valid_raw10(
    raw10: Array, pattern: str = "RGGB", roi_x: int = 0, roi_y: int = 0
) -> Array:
    """Bilinear four-pattern Debayer, returning only complete 3x3 centres.

    The returned RGB10 tensor has shape ``(H-2, W-2, 3)``. Output ``(0,0)``
    corresponds to local RAW coordinate ``(1,1)`` and absolute sensor
    coordinate ``(roi_x+1, roi_y+1)``.
    """
    raw = _require_raw10(raw10)
    effective = shifted_bayer_pattern(pattern, roi_x, roi_y)
    tile = np.asarray(_BAYER_TILES[effective])

    center = raw[1:-1, 1:-1]
    north = raw[:-2, 1:-1]
    south = raw[2:, 1:-1]
    west = raw[1:-1, :-2]
    east = raw[1:-1, 2:]
    north_west = raw[:-2, :-2]
    north_east = raw[:-2, 2:]
    south_west = raw[2:, :-2]
    south_east = raw[2:, 2:]

    cross = _avg4(north, south, west, east)
    diagonal = _avg4(north_west, north_east, south_west, south_east)
    horizontal = _avg2(west, east)
    vertical = _avg2(north, south)

    out_height, out_width = center.shape
    local_y, local_x = np.indices((out_height, out_width), dtype=np.int64)
    local_y += 1
    local_x += 1
    site = tile[local_y & 1, local_x & 1]
    horizontal_colour = tile[local_y & 1, (local_x + 1) & 1]

    red = np.empty_like(center)
    green = np.empty_like(center)
    blue = np.empty_like(center)

    red_site = site == "R"
    blue_site = site == "B"
    green_site = site == "G"
    green_r_horizontal = green_site & (horizontal_colour == "R")
    green_b_horizontal = green_site & (horizontal_colour == "B")

    red[red_site] = center[red_site]
    green[red_site] = cross[red_site]
    blue[red_site] = diagonal[red_site]

    blue[blue_site] = center[blue_site]
    green[blue_site] = cross[blue_site]
    red[blue_site] = diagonal[blue_site]

    green[green_site] = center[green_site]
    red[green_r_horizontal] = horizontal[green_r_horizontal]
    blue[green_r_horizontal] = vertical[green_r_horizontal]
    red[green_b_horizontal] = vertical[green_b_horizontal]
    blue[green_b_horizontal] = horizontal[green_b_horizontal]

    if not np.all(red_site | blue_site | green_r_horizontal | green_b_horizontal):
        raise AssertionError("Bayer classification left an unassigned pixel")
    return np.stack((red, green, blue), axis=-1).astype(np.uint16)


def apply_awb_q2_14(
    rgb10: Array, gains_q2_14: tuple[int, int, int] | Array
) -> Array:
    """Apply unsigned Q2.14 AWB and return a saturated RGB12 tensor."""
    image = np.asarray(rgb10)
    if image.ndim != 3 or image.shape[2] != 3:
        raise ValueError("AWB input must have shape HxWx3")
    values = image.astype(np.int64, copy=False)
    if np.any(values < 0) or np.any(values > 1023):
        raise ValueError("AWB input outside 0..1023")
    gains = np.asarray(gains_q2_14, dtype=np.int64).reshape(-1)
    if gains.shape != (3,) or np.any(gains < 0) or np.any(gains > 65535):
        raise ValueError("Q2.14 gains must contain three values in 0..65535")
    scaled = round_shift_away(values * gains.reshape(1, 1, 3), 14)
    return np.clip(scaled, 0, 4095).astype(np.uint16)


def apply_ccm_q3_13(
    rgb12: Array,
    matrix_q3_13: tuple[int, ...] | Array,
    offset_q13: tuple[int, int, int] | Array = (0, 0, 0),
) -> Array:
    """Apply a signed Q3.13 3x3 CCM and return saturated RGB10."""
    image = np.asarray(rgb12)
    if image.ndim != 3 or image.shape[2] != 3:
        raise ValueError("CCM input must have shape HxWx3")
    values = image.astype(np.int64, copy=False)
    if np.any(values < 0) or np.any(values > 4095):
        raise ValueError("CCM input outside 0..4095")
    matrix = np.asarray(matrix_q3_13, dtype=np.int64)
    if matrix.size != 9:
        raise ValueError("CCM must contain nine coefficients")
    matrix = matrix.reshape(3, 3)
    if np.any(matrix < -32768) or np.any(matrix > 32767):
        raise ValueError("Q3.13 CCM coefficient outside signed int16")
    offset = np.asarray(offset_q13, dtype=np.int64).reshape(-1)
    if offset.shape != (3,) or np.any(offset < -(1 << 31)) or np.any(offset > (1 << 31) - 1):
        raise ValueError("CCM offsets must contain three signed int32 values")

    accumulated = np.einsum("hwc,oc->hwo", values, matrix, optimize=True)
    accumulated += offset.reshape(1, 1, 3)
    quantized = round_shift_away(accumulated, 13)
    return sat_u10(quantized)


def apply_gamma_u10_to_u8(rgb10: Array, gamma_lut: Array) -> Array:
    """Index one normative 1024-entry RGB-shared Gamma LUT."""
    image = np.asarray(rgb10)
    if image.ndim != 3 or image.shape[2] != 3:
        raise ValueError("Gamma input must have shape HxWx3")
    values = image.astype(np.int64, copy=False)
    if np.any(values < 0) or np.any(values > 1023):
        raise ValueError("Gamma input outside 0..1023")
    lut = np.asarray(gamma_lut)
    if lut.shape != (1024,) or not np.issubdtype(lut.dtype, np.integer):
        raise ValueError("Gamma LUT must be one integer array of length 1024")
    lut_values = lut.astype(np.int64, copy=False)
    if np.any(lut_values < 0) or np.any(lut_values > 255):
        raise ValueError("Gamma LUT entry outside 0..255")
    return lut_values[values].astype(np.uint8)


def resize_axis_q16(input_size: int, output_size: int) -> tuple[int, int]:
    """Return normative ``(step_q16, phase0_q16)`` for one resize axis."""
    input_size = int(input_size)
    output_size = int(output_size)
    if input_size <= 0 or output_size <= 0:
        raise ValueError("resize dimensions must be positive")
    step = round_div_away(input_size << 16, output_size)
    phase0 = round_div_away((input_size - output_size) << 15, output_size)
    return step, phase0


def _axis_samples_q12(input_size: int, output_size: int) -> tuple[Array, Array, Array]:
    step, phase0 = resize_axis_q16(input_size, output_size)
    phase = phase0 + np.arange(output_size, dtype=np.int64) * step
    lower = phase >> 16
    fraction_q16 = phase - (lower << 16)
    upper = lower + 1
    weight_upper = np.minimum(4096, (fraction_q16 + 8) >> 4)
    lower_clamped = np.clip(lower, 0, input_size - 1)
    upper_clamped = np.clip(upper, 0, input_size - 1)
    return lower_clamped, upper_clamped, weight_upper


def resize_bilinear_q16_u8(image: Array, output_width: int, output_height: int) -> Array:
    """Centre-aligned, separable, bit-exact Q16.16/Q0.12 bilinear resize."""
    source = np.asarray(image)
    squeeze_channel = False
    if source.ndim == 2:
        source = source[..., None]
        squeeze_channel = True
    if source.ndim != 3 or source.shape[2] < 1:
        raise ValueError("resize input must have shape HxW or HxWxC")
    if not np.issubdtype(source.dtype, np.integer):
        raise TypeError("resize input must contain integers")
    source_i = source.astype(np.int64, copy=False)
    if np.any(source_i < 0) or np.any(source_i > 255):
        raise ValueError("resize input outside 0..255")
    output_width = int(output_width)
    output_height = int(output_height)
    if output_width <= 0 or output_height <= 0:
        raise ValueError("resize dimensions must be positive")

    x0, x1, wx1 = _axis_samples_q12(source.shape[1], output_width)
    y0, y1, wy1 = _axis_samples_q12(source.shape[0], output_height)
    wx1_b = wx1.reshape(1, output_width, 1)
    wx0_b = 4096 - wx1_b
    wy1_b = wy1.reshape(output_height, 1, 1)
    wy0_b = 4096 - wy1_b

    top_left = source_i[y0[:, None], x0[None, :], :]
    top_right = source_i[y0[:, None], x1[None, :], :]
    bottom_left = source_i[y1[:, None], x0[None, :], :]
    bottom_right = source_i[y1[:, None], x1[None, :], :]

    horizontal_top = (wx0_b * top_left + wx1_b * top_right + 2048) >> 12
    horizontal_bottom = (wx0_b * bottom_left + wx1_b * bottom_right + 2048) >> 12
    output = (wy0_b * horizontal_top + wy1_b * horizontal_bottom + 2048) >> 12
    result = sat_u8(output)
    return result[..., 0] if squeeze_channel else result


def run_r1_isp(
    raw10_roi: Array,
    output_width: int,
    output_height: int,
    config: R1ISPConfig | None = None,
) -> tuple[Array, dict[str, Array | str]]:
    """Run the complete integer R1 ISP and return output plus stage tensors."""
    config = config or R1ISPConfig()
    pattern = _validate_pattern(config.bayer_pattern)
    blc = black_level_correct_raw10(
        raw10_roi,
        config.black_levels,
        config.roi_x,
        config.roi_y,
        pattern,
    )
    demosaic = demosaic_bilinear_valid_raw10(
        blc, pattern, config.roi_x, config.roi_y
    )
    awb = apply_awb_q2_14(demosaic, config.awb_gain_q2_14)
    ccm = apply_ccm_q3_13(awb, config.ccm_q3_13, config.ccm_offset_q13)
    gamma = apply_gamma_u10_to_u8(ccm, config.gamma_lut)
    resized = resize_bilinear_q16_u8(gamma, output_width, output_height)
    stages: dict[str, Array | str] = {
        "blc_raw10": blc,
        "demosaic_rgb10": demosaic,
        "awb_rgb12": awb,
        "ccm_rgb10": ccm,
        "gamma_rgb8": gamma,
        "resize_rgb8": resized,
        "effective_bayer": shifted_bayer_pattern(pattern, config.roi_x, config.roi_y),
    }
    return resized, stages


__all__ = [
    "Array",
    "BAYER_PATTERN_CODES",
    "BAYER_PATTERNS",
    "R1ISPConfig",
    "apply_awb_q2_14",
    "apply_ccm_q3_13",
    "apply_gamma_u10_to_u8",
    "bayer_phase_indices",
    "black_level_correct_raw10",
    "demosaic_bilinear_valid_raw10",
    "identity_gamma_lut",
    "resize_axis_q16",
    "resize_bilinear_q16_u8",
    "rgb8_to_bayer10",
    "round_div_away",
    "round_shift_away",
    "run_r1_isp",
    "sat_u8",
    "sat_u10",
    "shifted_bayer_pattern",
]

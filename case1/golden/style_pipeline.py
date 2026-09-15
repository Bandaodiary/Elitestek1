"""Board-independent golden model for contest problem 1.

The module mirrors the arithmetic used by the R0 portable RTL where explicitly
covered by exported vectors.  In particular, the RTL compares only the
interior of the full-size edge-padded Python demosaic result:

* MIPI RAW10 four-pixel/five-byte packing and unpacking.
* RGGB Bayer generation and integer bilinear demosaic.
* Integer nearest-neighbour resize.
* A compact three-stage INT8 CNN:
    3x3 RGB convolution -> clamp/ReLU
    3x3 depthwise convolution -> clamp/ReLU
    1x1 pointwise convolution -> clamp

The default ``vivid_paint`` weights are deterministic, hand-authored baseline
weights.  They implement smoothing, local sharpening, and colour expansion.
They are not presented as a trained artistic model; the same inference and
weight-export path can consume trained weights later without changing RTL.
"""

from __future__ import annotations

import argparse
import json
import math
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Sequence

import numpy as np
from PIL import Image


Array = np.ndarray


def load_rgb(path: Path) -> Array:
    """Load an image as HxWx3 uint8 RGB."""
    with Image.open(path) as image:
        return np.asarray(image.convert("RGB"), dtype=np.uint8)


def save_rgb(path: Path, rgb: Array) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    Image.fromarray(np.asarray(rgb, dtype=np.uint8), mode="RGB").save(path)


def resize_nearest_u8(image: Array, out_width: int, out_height: int) -> Array:
    """RTL-friendly nearest-neighbour resize using integer source indices."""
    if out_width <= 0 or out_height <= 0:
        raise ValueError("output dimensions must be positive")
    in_height, in_width = image.shape[:2]
    # Pixel-centre mapping, expressed entirely with integer arithmetic.
    x = ((2 * np.arange(out_width, dtype=np.int64) + 1) * in_width) // (2 * out_width)
    y = ((2 * np.arange(out_height, dtype=np.int64) + 1) * in_height) // (2 * out_height)
    x = np.minimum(x, in_width - 1)
    y = np.minimum(y, in_height - 1)
    return np.asarray(image[y[:, None], x[None, :]], dtype=np.uint8)


def rgb8_to_rggb10(rgb: Array) -> Array:
    """Sample an RGB image with an RGGB colour filter array at 10 bits."""
    rgb10 = np.asarray(rgb, dtype=np.uint16) << 2
    raw = np.empty(rgb.shape[:2], dtype=np.uint16)
    raw[0::2, 0::2] = rgb10[0::2, 0::2, 0]  # R
    raw[0::2, 1::2] = rgb10[0::2, 1::2, 1]  # G on R row
    raw[1::2, 0::2] = rgb10[1::2, 0::2, 1]  # G on B row
    raw[1::2, 1::2] = rgb10[1::2, 1::2, 2]  # B
    return raw


def raw10_pack(pixels: Array) -> bytes:
    """Pack a flat sequence using CSI-2 RAW10 four-pixel/five-byte groups."""
    flat = np.asarray(pixels, dtype=np.uint16).reshape(-1)
    if flat.size % 4:
        raise ValueError("RAW10 packing requires a multiple of four pixels")
    if np.any(flat > 1023):
        raise ValueError("RAW10 pixel outside 0..1023")
    group = flat.reshape(-1, 4)
    out = np.empty((group.shape[0], 5), dtype=np.uint8)
    out[:, 0:4] = (group >> 2).astype(np.uint8)
    out[:, 4] = (
        (group[:, 0] & 3)
        | ((group[:, 1] & 3) << 2)
        | ((group[:, 2] & 3) << 4)
        | ((group[:, 3] & 3) << 6)
    ).astype(np.uint8)
    return out.tobytes()


def raw10_unpack(payload: bytes) -> Array:
    """Inverse of :func:`raw10_pack`, returning flat uint16 pixels."""
    raw = np.frombuffer(payload, dtype=np.uint8)
    if raw.size % 5:
        raise ValueError("RAW10 payload length must be a multiple of five")
    group = raw.reshape(-1, 5).astype(np.uint16)
    low = group[:, 4]
    pixels = np.empty((group.shape[0], 4), dtype=np.uint16)
    pixels[:, 0] = (group[:, 0] << 2) | (low & 3)
    pixels[:, 1] = (group[:, 1] << 2) | ((low >> 2) & 3)
    pixels[:, 2] = (group[:, 2] << 2) | ((low >> 4) & 3)
    pixels[:, 3] = (group[:, 3] << 2) | ((low >> 6) & 3)
    return pixels.reshape(-1)


def _avg_round(values: Sequence[Array]) -> Array:
    total = np.zeros_like(values[0], dtype=np.uint32)
    for value in values:
        total += np.asarray(value, dtype=np.uint32)
    return ((total + len(values) // 2) // len(values)).astype(np.uint16)


def demosaic_rggb10_bilinear(raw10: Array) -> Array:
    """Integer bilinear RGGB demosaic with replicated one-pixel borders.

    The output is RGB888.  Interpolation is performed at 10-bit precision and
    rounded before the final 10-to-8-bit conversion.
    """
    raw = np.asarray(raw10, dtype=np.uint16)
    if raw.ndim != 2:
        raise ValueError("raw Bayer image must be two-dimensional")
    padded = np.pad(raw, ((1, 1), (1, 1)), mode="edge")
    c = padded[1:-1, 1:-1]
    n = padded[:-2, 1:-1]
    s = padded[2:, 1:-1]
    w = padded[1:-1, :-2]
    e = padded[1:-1, 2:]
    nw = padded[:-2, :-2]
    ne = padded[:-2, 2:]
    sw = padded[2:, :-2]
    se = padded[2:, 2:]

    height, width = raw.shape
    yy, xx = np.indices((height, width))
    r_site = ((yy & 1) == 0) & ((xx & 1) == 0)
    b_site = ((yy & 1) == 1) & ((xx & 1) == 1)
    g_r_row = ((yy & 1) == 0) & ((xx & 1) == 1)
    g_b_row = ((yy & 1) == 1) & ((xx & 1) == 0)

    red = np.empty_like(raw)
    green = np.empty_like(raw)
    blue = np.empty_like(raw)

    red[r_site] = c[r_site]
    green[r_site] = _avg_round((n, s, w, e))[r_site]
    blue[r_site] = _avg_round((nw, ne, sw, se))[r_site]

    blue[b_site] = c[b_site]
    green[b_site] = _avg_round((n, s, w, e))[b_site]
    red[b_site] = _avg_round((nw, ne, sw, se))[b_site]

    green[g_r_row] = c[g_r_row]
    red[g_r_row] = _avg_round((w, e))[g_r_row]
    blue[g_r_row] = _avg_round((n, s))[g_r_row]

    green[g_b_row] = c[g_b_row]
    red[g_b_row] = _avg_round((n, s))[g_b_row]
    blue[g_b_row] = _avg_round((w, e))[g_b_row]

    rgb10 = np.stack((red, green, blue), axis=-1).astype(np.uint32)
    return np.clip((rgb10 + 2) >> 2, 0, 255).astype(np.uint8)


def round_shift_away_from_zero(values: Array, shift: int) -> Array:
    """Signed power-of-two requantization used by the RTL."""
    values = np.asarray(values, dtype=np.int64)
    if shift < 0:
        return values << (-shift)
    if shift == 0:
        return values
    magnitude = np.abs(values)
    rounded = (magnitude + (1 << (shift - 1))) >> shift
    return np.where(values < 0, -rounded, rounded)


def clamp_u8(values: Array) -> Array:
    return np.clip(values, 0, 255).astype(np.uint8)


def conv3x3_valid_u8(
    image: Array, weights: Array, bias: Array, shift: int, relu: bool = True
) -> Array:
    """Valid 3x3 convolution, signed INT8 weights and signed INT32 bias."""
    image_i = np.asarray(image, dtype=np.int32)
    weight_i = np.asarray(weights, dtype=np.int32)
    bias_i = np.asarray(bias, dtype=np.int64)
    if image_i.ndim != 3 or weight_i.ndim != 4:
        raise ValueError("expected HWC image and OIHW weights")
    out_channels, in_channels, kh, kw = weight_i.shape
    if (kh, kw) != (3, 3) or image_i.shape[2] != in_channels:
        raise ValueError("3x3 convolution shape mismatch")
    out_h, out_w = image_i.shape[0] - 2, image_i.shape[1] - 2
    accum = np.broadcast_to(bias_i, (out_h, out_w, out_channels)).copy()
    for ky in range(3):
        for kx in range(3):
            patch = image_i[ky : ky + out_h, kx : kx + out_w, :]
            accum += np.einsum("hwc,oc->hwo", patch, weight_i[:, :, ky, kx], optimize=True)
    quant = round_shift_away_from_zero(accum, shift)
    if relu:
        return clamp_u8(quant)
    return np.clip(quant, -32768, 32767).astype(np.int16)


def depthwise3x3_valid_u8(
    image: Array, weights: Array, bias: Array, shift: int, relu: bool = True
) -> Array:
    image_i = np.asarray(image, dtype=np.int32)
    weight_i = np.asarray(weights, dtype=np.int32)
    bias_i = np.asarray(bias, dtype=np.int64)
    if weight_i.shape != (image_i.shape[2], 3, 3):
        raise ValueError("depthwise weight shape mismatch")
    out_h, out_w = image_i.shape[0] - 2, image_i.shape[1] - 2
    accum = np.broadcast_to(bias_i, (out_h, out_w, image_i.shape[2])).copy()
    for ky in range(3):
        for kx in range(3):
            accum += image_i[ky : ky + out_h, kx : kx + out_w, :] * weight_i[:, ky, kx]
    quant = round_shift_away_from_zero(accum, shift)
    return clamp_u8(quant) if relu else np.clip(quant, -32768, 32767).astype(np.int16)


def pointwise1x1_u8(
    image: Array, weights: Array, bias: Array, shift: int
) -> Array:
    image_i = np.asarray(image, dtype=np.int32)
    weight_i = np.asarray(weights, dtype=np.int32)
    bias_i = np.asarray(bias, dtype=np.int64)
    accum = np.einsum("hwc,oc->hwo", image_i, weight_i, optimize=True)
    accum += bias_i
    return clamp_u8(round_shift_away_from_zero(accum, shift))


@dataclass(frozen=True)
class TinyStyleWeights:
    conv1_w: Array  # [3,3,3,3] OIHW
    conv1_b: Array  # [3]
    conv1_shift: int
    depthwise_w: Array  # [3,3,3] CHW
    depthwise_b: Array  # [3]
    depthwise_shift: int
    pointwise_w: Array  # [3,3] OI
    pointwise_b: Array  # [3]
    pointwise_shift: int
    name: str = "vivid_paint"


def vivid_paint_weights() -> TinyStyleWeights:
    """Deterministic baseline weights for the portable RTL regression."""
    gaussian = np.array([[1, 2, 1], [2, 4, 2], [1, 2, 1]], dtype=np.int8)
    conv1 = np.zeros((3, 3, 3, 3), dtype=np.int8)
    for channel in range(3):
        conv1[channel, channel] = gaussian
    sharpen = np.array([[0, -1, 0], [-1, 5, -1], [0, -1, 0]], dtype=np.int8)
    depthwise = np.stack((sharpen, sharpen, sharpen), axis=0)
    pointwise = np.array([[10, -1, -1], [-1, 10, -1], [-1, -1, 10]], dtype=np.int8)
    return TinyStyleWeights(
        conv1_w=conv1,
        conv1_b=np.zeros(3, dtype=np.int32),
        conv1_shift=4,
        depthwise_w=depthwise,
        depthwise_b=np.zeros(3, dtype=np.int32),
        depthwise_shift=0,
        pointwise_w=pointwise,
        pointwise_b=np.zeros(3, dtype=np.int32),
        pointwise_shift=3,
    )


def tiny_style_infer(image: Array, weights: TinyStyleWeights | None = None) -> tuple[Array, dict[str, Array]]:
    """Run the complete integer CNN and return output plus layer tensors."""
    weights = weights or vivid_paint_weights()
    layer1 = conv3x3_valid_u8(
        image, weights.conv1_w, weights.conv1_b, weights.conv1_shift, relu=True
    )
    layer2 = depthwise3x3_valid_u8(
        layer1,
        weights.depthwise_w,
        weights.depthwise_b,
        weights.depthwise_shift,
        relu=True,
    )
    output = pointwise1x1_u8(
        layer2, weights.pointwise_w, weights.pointwise_b, weights.pointwise_shift
    )
    return output, {"conv1": layer1, "depthwise": layer2, "output": output}


def psnr_u8(reference: Array, observed: Array) -> float:
    ref = np.asarray(reference, dtype=np.float64)
    obs = np.asarray(observed, dtype=np.float64)
    mse = float(np.mean((ref - obs) ** 2))
    if mse == 0:
        return math.inf
    return 10.0 * math.log10((255.0**2) / mse)


def saturation_fraction(image: Array) -> float:
    values = np.asarray(image, dtype=np.uint8)
    return float(np.mean((values == 0) | (values == 255)))


def write_hex_rgb24(path: Path, image: Array) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    rgb = np.asarray(image, dtype=np.uint8).reshape(-1, 3)
    with path.open("w", encoding="ascii", newline="\n") as stream:
        for red, green, blue in rgb:
            stream.write(f"{int(red):02x}{int(green):02x}{int(blue):02x}\n")


def _write_signed_hex(path: Path, values: Iterable[int], bits: int) -> None:
    mask = (1 << bits) - 1
    width = (bits + 3) // 4
    with path.open("w", encoding="ascii", newline="\n") as stream:
        for value in values:
            stream.write(f"{int(value) & mask:0{width}x}\n")


def export_weights(directory: Path, weights: TinyStyleWeights | None = None) -> dict[str, str]:
    weights = weights or vivid_paint_weights()
    directory.mkdir(parents=True, exist_ok=True)
    files = {
        "conv1_w": "conv1_w_i8.hex",
        "conv1_b": "conv1_b_i32.hex",
        "depthwise_w": "depthwise_w_i8.hex",
        "depthwise_b": "depthwise_b_i32.hex",
        "pointwise_w": "pointwise_w_i8.hex",
        "pointwise_b": "pointwise_b_i32.hex",
    }
    _write_signed_hex(directory / files["conv1_w"], weights.conv1_w.reshape(-1), 8)
    _write_signed_hex(directory / files["conv1_b"], weights.conv1_b.reshape(-1), 32)
    _write_signed_hex(directory / files["depthwise_w"], weights.depthwise_w.reshape(-1), 8)
    _write_signed_hex(directory / files["depthwise_b"], weights.depthwise_b.reshape(-1), 32)
    _write_signed_hex(directory / files["pointwise_w"], weights.pointwise_w.reshape(-1), 8)
    _write_signed_hex(directory / files["pointwise_b"], weights.pointwise_b.reshape(-1), 32)
    manifest = {
        "name": weights.name,
        "tensor_layout": "RGB/HWC activations; OIHW conv1; CHW depthwise; OI pointwise",
        "rounding": "round absolute magnitude to nearest, ties away from zero",
        "activation": "clamp 0..255 after every layer",
        "conv1_shift": weights.conv1_shift,
        "depthwise_shift": weights.depthwise_shift,
        "pointwise_shift": weights.pointwise_shift,
        "files": files,
    }
    (directory / "manifest.json").write_text(
        json.dumps(manifest, indent=2, ensure_ascii=False), encoding="utf-8"
    )
    return files


def make_side_by_side(left: Array, right: Array) -> Array:
    height = min(left.shape[0], right.shape[0])
    left_crop = left[:height]
    right_crop = right[:height]
    if left_crop.shape[0] != right_crop.shape[0]:
        raise AssertionError("height mismatch")
    return np.concatenate((left_crop, right_crop), axis=1)


def run_image(path: Path, output_root: Path, width: int, height: int) -> dict[str, object]:
    source = load_rgb(path)
    resized = resize_nearest_u8(source, width, height)
    raw10 = rgb8_to_rggb10(resized)
    packed = raw10_pack(raw10.reshape(-1))
    unpacked = raw10_unpack(packed).reshape(raw10.shape)
    if not np.array_equal(raw10, unpacked):
        raise AssertionError("RAW10 pack/unpack round-trip failed")
    reconstructed = demosaic_rggb10_bilinear(unpacked)
    styled, layers = tiny_style_infer(reconstructed)
    # The two valid 3x3 stages remove two pixels at every side.
    reference_crop = reconstructed[2:-2, 2:-2]

    output_dir = output_root / path.stem
    output_dir.mkdir(parents=True, exist_ok=True)
    save_rgb(output_dir / "input_rgb.png", resized)
    save_rgb(output_dir / "sensor_reconstructed.png", reconstructed)
    save_rgb(output_dir / "style_output.png", styled)
    save_rgb(output_dir / "comparison.png", make_side_by_side(reference_crop, styled))
    for layer_name, tensor in layers.items():
        save_rgb(output_dir / f"layer_{layer_name}.png", tensor)

    metrics: dict[str, object] = {
        "input": path.name,
        "source_size": [int(source.shape[1]), int(source.shape[0])],
        "processed_size": [width, height],
        "style_output_size": [int(styled.shape[1]), int(styled.shape[0])],
        "raw10_bytes": len(packed),
        "raw10_roundtrip_exact": True,
        "demosaic_psnr_db": psnr_u8(resized, reconstructed),
        "style_saturation_fraction": saturation_fraction(styled),
        "layer_ranges": {
            name: [int(value.min()), int(value.max())] for name, value in layers.items()
        },
    }
    (output_dir / "metrics.json").write_text(
        json.dumps(metrics, indent=2, ensure_ascii=False), encoding="utf-8"
    )
    return metrics


def generate_rtl_vectors(image_path: Path, vector_dir: Path, width: int = 16, height: int = 12) -> dict[str, int]:
    source = resize_nearest_u8(load_rgb(image_path), width, height)
    expected, layers = tiny_style_infer(source)
    vector_dir.mkdir(parents=True, exist_ok=True)
    write_hex_rgb24(vector_dir / "cnn_input_rgb24.hex", source)
    write_hex_rgb24(vector_dir / "cnn_expected_rgb24.hex", expected)
    write_hex_rgb24(vector_dir / "cnn_expected_conv1_rgb24.hex", layers["conv1"])
    write_hex_rgb24(vector_dir / "cnn_expected_depthwise_rgb24.hex", layers["depthwise"])
    metadata = {
        "input_width": width,
        "input_height": height,
        "output_width": width - 4,
        "output_height": height - 4,
        "input_pixels": width * height,
        "output_pixels": (width - 4) * (height - 4),
    }
    (vector_dir / "cnn_vectors.json").write_text(
        json.dumps(metadata, indent=2), encoding="utf-8"
    )
    return metadata


def discover_images(directory: Path) -> list[Path]:
    paths: list[Path] = []
    for suffix in ("*.png", "*.jpg", "*.jpeg", "*.tif", "*.tiff", "*.bmp"):
        paths.extend(directory.glob(suffix))
    valid: list[Path] = []
    for path in sorted(set(paths)):
        try:
            with Image.open(path) as image:
                image.verify()
            valid.append(path)
        except Exception:
            # Download repositories occasionally contain uncommon TIFF
            # encodings.  Invalid/unsupported files are reported by the CLI.
            print(f"SKIP_UNREADABLE {path}")
    return valid


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--images", type=Path, default=Path("assets/images"))
    parser.add_argument("--output", type=Path, default=Path("outputs/golden"))
    parser.add_argument("--weights", type=Path, default=Path("model/vivid_paint"))
    parser.add_argument("--vectors", type=Path, default=Path("sim/vectors"))
    parser.add_argument("--width", type=int, default=256)
    parser.add_argument("--height", type=int, default=256)
    parser.add_argument("--vector-image", type=Path)
    args = parser.parse_args()

    images = discover_images(args.images)
    if not images:
        raise SystemExit(f"no readable images found in {args.images}")
    args.output.mkdir(parents=True, exist_ok=True)
    export_weights(args.weights)

    summary = []
    for image_path in images:
        metrics = run_image(image_path, args.output, args.width, args.height)
        summary.append(metrics)
        print(
            f"GOLDEN_OK {image_path.name} "
            f"demosaic_psnr={metrics['demosaic_psnr_db']:.3f}dB "
            f"output={metrics['style_output_size']}"
        )

    vector_image = args.vector_image or images[0]
    vector_meta = generate_rtl_vectors(vector_image, args.vectors)
    report = {
        "images": summary,
        "rtl_vector_image": vector_image.name,
        "rtl_vectors": vector_meta,
    }
    (args.output / "summary.json").write_text(
        json.dumps(report, indent=2, ensure_ascii=False), encoding="utf-8"
    )
    print(f"RTL_VECTORS_OK {vector_image.name} {vector_meta}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

"""MicroStyle-24 BN folding, QAT arithmetic and bit-exact INT8 export.

The exported arithmetic matches the R1 primitive contract:

* signed INT8 activations and weights;
* signed INT32 accumulators and biases;
* per-output-channel signed-18 multiplier plus a 0..47 right shift;
* round-to-nearest with midpoint away from zero;
* saturating signed INT8 ReLU/residual operations.

This module deliberately has no torchvision dependency.  It is shared by the
training program and the artifact regression test.
"""

from __future__ import annotations

from copy import deepcopy
import json
import math
from pathlib import Path
from typing import Iterable

import numpy as np
import torch
from torch import Tensor, nn
from torch.nn import functional as F

from microstyle_layout import build_layout, layer_specs


CONV_NAMES = (
    "encoder1.conv3x3_s2",
    "encoder2.conv3x3_s2",
    "res0.expand1x1",
    "res0.depthwise3x3",
    "res0.project1x1",
    "res1.expand1x1",
    "res1.depthwise3x3",
    "res1.project1x1",
    "res2.expand1x1",
    "res2.depthwise3x3",
    "res2.project1x1",
    "decoder1.depthwise3x3",
    "decoder1.pointwise1x1",
    "decoder2.depthwise3x3",
    "decoder2.pointwise1x1",
    "output.conv3x3",
)

BOTTLENECK_NAMES = (
    "encoder2.conv3x3_s2",
    "res0.project1x1",
    "res0.add_relu",
    "res1.project1x1",
    "res1.add_relu",
    "res2.project1x1",
    "res2.add_relu",
)


def convolution_modules(model: nn.Module) -> dict[str, nn.Conv2d]:
    """Return the frozen descriptor-name to PyTorch-module mapping."""
    available: dict[str, nn.Conv2d] = {
        "encoder1.conv3x3_s2": model.encoder1,
        "encoder2.conv3x3_s2": model.encoder2,
        "decoder1.depthwise3x3": model.decoder1.depthwise,
        "decoder1.pointwise1x1": model.decoder1.pointwise,
        "decoder2.depthwise3x3": model.decoder2.depthwise,
        "decoder2.pointwise1x1": model.decoder2.pointwise,
        "output.conv3x3": model.output,
    }
    for block_index, block in enumerate(model.residual):
        available[f"res{block_index}.expand1x1"] = block.expand
        available[f"res{block_index}.depthwise3x3"] = block.depthwise
        available[f"res{block_index}.project1x1"] = block.project
    if set(available) != set(CONV_NAMES):
        raise RuntimeError(f"MicroStyle convolution set changed: {tuple(available)}")
    rows = {name: available[name] for name in CONV_NAMES}
    return rows


def _fold_pair(conv: nn.Conv2d, norm: nn.BatchNorm2d) -> None:
    if not isinstance(norm, nn.BatchNorm2d):
        raise TypeError("expected BatchNorm2d before folding")
    with torch.no_grad():
        weight = conv.weight.detach()
        bias = (
            conv.bias.detach()
            if conv.bias is not None
            else torch.zeros(conv.out_channels, device=weight.device, dtype=weight.dtype)
        )
        gain = norm.weight.detach() / torch.sqrt(norm.running_var.detach() + norm.eps)
        folded_weight = weight * gain.reshape(-1, 1, 1, 1)
        folded_bias = (bias - norm.running_mean.detach()) * gain + norm.bias.detach()
        conv.weight = nn.Parameter(folded_weight.clone())
        conv.bias = nn.Parameter(folded_bias.clone())


def fuse_batch_norms(model: nn.Module) -> nn.Module:
    """Deep-copy a trained MicroStyle-24 and fold every BatchNorm into Conv."""
    fused = deepcopy(model).eval()
    _fold_pair(fused.encoder1, fused.encoder1_norm)
    fused.encoder1_norm = nn.Identity()
    _fold_pair(fused.encoder2, fused.encoder2_norm)
    fused.encoder2_norm = nn.Identity()
    for block in fused.residual:
        _fold_pair(block.expand, block.expand_norm)
        block.expand_norm = nn.Identity()
        _fold_pair(block.depthwise, block.depthwise_norm)
        block.depthwise_norm = nn.Identity()
        _fold_pair(block.project, block.project_norm)
        block.project_norm = nn.Identity()
    for decoder in (fused.decoder1, fused.decoder2):
        _fold_pair(decoder.depthwise, decoder.depthwise_norm)
        decoder.depthwise_norm = nn.Identity()
        _fold_pair(decoder.pointwise, decoder.pointwise_norm)
        decoder.pointwise_norm = nn.Identity()
    _fold_pair(fused.output, fused.output_norm)
    fused.output_norm = nn.Identity()
    return fused


def _input_real(rgb01: Tensor) -> Tensor:
    clipped = torch.clamp(rgb01, 0.0, 1.0)
    code_float = clipped * 255.0
    code = code_float + (torch.round(code_float) - code_float).detach()
    return (code - 128.0) / 128.0


def fused_float_forward(
    model: nn.Module, rgb01: Tensor, collect: bool = False
) -> tuple[Tensor, dict[str, Tensor]]:
    """Forward a BN-folded model and optionally expose descriptor tensors."""
    layers: dict[str, Tensor] = {}

    def record(name: str, value: Tensor) -> Tensor:
        if collect:
            layers[name] = value
        return value

    value = _input_real(rgb01)
    value = record("encoder1.conv3x3_s2", F.relu(model.encoder1(value)))
    value = record("encoder2.conv3x3_s2", F.relu(model.encoder2(value)))
    for block_index, block in enumerate(model.residual):
        skip = value
        value = record(
            f"res{block_index}.expand1x1", F.relu(block.expand(value))
        )
        value = record(
            f"res{block_index}.depthwise3x3", F.relu(block.depthwise(value))
        )
        value = record(f"res{block_index}.project1x1", block.project(value))
        value = record(f"res{block_index}.add_relu", F.relu(value + skip))
    value = F.interpolate(value, scale_factor=2, mode="nearest")
    if collect:
        layers["decoder1.upsample2"] = value
    value = record("decoder1.depthwise3x3", F.relu(model.decoder1.depthwise(value)))
    value = record("decoder1.pointwise1x1", F.relu(model.decoder1.pointwise(value)))
    value = F.interpolate(value, scale_factor=2, mode="nearest")
    if collect:
        layers["decoder2.upsample2"] = value
    value = record("decoder2.depthwise3x3", F.relu(model.decoder2.depthwise(value)))
    value = record("decoder2.pointwise1x1", F.relu(model.decoder2.pointwise(value)))
    value = record("output.conv3x3", model.output(value))
    value = torch.clamp(value, -1.0, 127.0 / 128.0)
    output_code_float = value * 128.0 + 128.0
    output_code = output_code_float + (
        torch.round(output_code_float) - output_code_float
    ).detach()
    output = torch.clamp(output_code, 0.0, 255.0) / 255.0
    if collect:
        layers["output.s8_to_rgb"] = output
    return output, layers


def calibrate_activation_scales(
    model: nn.Module,
    batches: Iterable[Tensor],
    headroom_code: int = 120,
) -> dict[str, float]:
    """Calibrate fixed symmetric scales from representative content batches."""
    if not 1 <= headroom_code <= 127:
        raise ValueError("headroom_code must be in 1..127")
    peaks: dict[str, float] = {}
    model.eval()
    with torch.no_grad():
        for batch in batches:
            _, layers = fused_float_forward(model, batch, collect=True)
            for name, tensor in layers.items():
                if name == "output.s8_to_rgb" or "upsample2" in name:
                    continue
                peak = float(tensor.detach().abs().amax().cpu())
                peaks[name] = max(peaks.get(name, 0.0), peak)
    missing = set(CONV_NAMES) - set(peaks)
    if missing:
        raise RuntimeError(f"calibration did not observe layers: {sorted(missing)}")

    minimum = 1.0 / 32768.0
    scales = {
        name: max(peaks[name] / float(headroom_code), minimum)
        for name in CONV_NAMES
    }
    # Direct residual addition has no rescale primitive.  Encoder2, all project
    # outputs and all residual-add outputs therefore share one code scale.
    bottleneck_peak = max(peaks[name] for name in BOTTLENECK_NAMES)
    bottleneck_scale = max(bottleneck_peak / float(headroom_code), minimum)
    for name in BOTTLENECK_NAMES:
        scales[name] = bottleneck_scale
    # OUTPUT_RGB is specified as signed-code + 128, so the final real-domain
    # scale is frozen rather than calibrated.
    scales["output.conv3x3"] = 1.0 / 128.0
    return scales


def _weight_scales(model: nn.Module) -> dict[str, np.ndarray]:
    rows: dict[str, np.ndarray] = {}
    for name, conv in convolution_modules(model).items():
        weight = conv.weight.detach().cpu().numpy().astype(np.float64)
        peaks = np.max(np.abs(weight).reshape(weight.shape[0], -1), axis=1)
        rows[name] = np.maximum(peaks / 127.0, 1.0 / (1 << 24))
    return rows


def choose_multiplier_shift(ratio: float) -> tuple[int, int]:
    """Approximate a positive scale ratio by signed18 / 2**shift."""
    if not math.isfinite(ratio) or ratio <= 0.0:
        raise ValueError(f"invalid requant ratio {ratio}")
    maximum = (1 << 17) - 1
    for shift in range(47, -1, -1):
        multiplier = int(math.floor(ratio * (1 << shift) + 0.5))
        if 1 <= multiplier <= maximum:
            return multiplier, shift
    raise ValueError(f"requant ratio cannot fit signed18/shift47: {ratio}")


def _conv_input_scales(activation_scales: dict[str, float]) -> dict[str, float]:
    rows = {
        "encoder1.conv3x3_s2": 1.0 / 128.0,
        "encoder2.conv3x3_s2": activation_scales["encoder1.conv3x3_s2"],
    }
    for block_index in range(3):
        prefix = f"res{block_index}"
        skip_name = (
            "encoder2.conv3x3_s2" if block_index == 0
            else f"res{block_index - 1}.add_relu"
        )
        rows[f"{prefix}.expand1x1"] = activation_scales[skip_name]
        rows[f"{prefix}.depthwise3x3"] = activation_scales[f"{prefix}.expand1x1"]
        rows[f"{prefix}.project1x1"] = activation_scales[f"{prefix}.depthwise3x3"]
    rows["decoder1.depthwise3x3"] = activation_scales["res2.add_relu"]
    rows["decoder1.pointwise1x1"] = activation_scales["decoder1.depthwise3x3"]
    rows["decoder2.depthwise3x3"] = activation_scales["decoder1.pointwise1x1"]
    rows["decoder2.pointwise1x1"] = activation_scales["decoder2.depthwise3x3"]
    rows["output.conv3x3"] = activation_scales["decoder2.pointwise1x1"]
    return rows


def build_quant_parameters(
    model: nn.Module,
    activation_scales: dict[str, float],
    weight_scales: dict[str, np.ndarray] | None = None,
) -> dict[str, dict[str, object]]:
    weights = weight_scales or _weight_scales(model)
    inputs = _conv_input_scales(activation_scales)
    rows: dict[str, dict[str, object]] = {}
    for name in CONV_NAMES:
        output_scale = activation_scales[name]
        multipliers = []
        shifts = []
        for weight_scale in weights[name]:
            multiplier, shift = choose_multiplier_shift(
                inputs[name] * float(weight_scale) / output_scale
            )
            multipliers.append(multiplier)
            shifts.append(shift)
        rows[name] = {
            "input_scale": inputs[name],
            "output_scale": output_scale,
            "weight_scales": np.asarray(weights[name], dtype=np.float64),
            "multipliers": np.asarray(multipliers, dtype=np.int32),
            "shifts": np.asarray(shifts, dtype=np.uint8),
        }
    return rows


def _round_ste(value: Tensor) -> Tensor:
    """Straight-through nearest rounding with midpoint away from zero."""
    rounded = torch.sign(value) * torch.floor(torch.abs(value) + 0.5)
    return value + (rounded - value).detach()


def _round_shift_away_ste(product: Tensor, shifts: Tensor) -> Tensor:
    product64 = product.to(torch.float64)
    shifts64 = shifts.to(device=product.device, dtype=torch.float64).reshape(1, -1, 1, 1)
    denominator = torch.pow(2.0, shifts64)
    proxy = product64 / denominator
    half = torch.where(shifts64 > 0.0, denominator / 2.0, torch.zeros_like(denominator))
    exact = torch.sign(product64) * torch.floor((torch.abs(product64) + half) / denominator)
    return (proxy + (exact - proxy).detach()).to(torch.float32)


class QATMicroStyle24(nn.Module):
    """BN-folded MicroStyle-24 executing the exact exported code grid."""

    def __init__(
        self,
        model: nn.Module,
        activation_scales: dict[str, float],
        weight_scales: dict[str, np.ndarray] | None = None,
    ) -> None:
        super().__init__()
        self.model = model
        self.activation_scales = dict(activation_scales)
        self.quant_parameters = build_quant_parameters(
            model, self.activation_scales, weight_scales
        )

    def serializable_weight_scales(self) -> dict[str, list[float]]:
        return {
            name: np.asarray(row["weight_scales"]).astype(float).tolist()
            for name, row in self.quant_parameters.items()
        }

    def _conv(self, name: str, codes: Tensor, relu: bool) -> Tensor:
        conv = convolution_modules(self.model)[name]
        row = self.quant_parameters[name]
        weight_scale = torch.as_tensor(
            row["weight_scales"], device=codes.device, dtype=torch.float32
        ).reshape(-1, 1, 1, 1)
        qweight = torch.clamp(
            _round_ste(conv.weight / weight_scale), -127.0, 127.0
        )
        if conv.bias is None:
            bias = torch.zeros(conv.out_channels, device=codes.device)
        else:
            bias_scale = torch.as_tensor(
                np.asarray(row["weight_scales"]) * float(row["input_scale"]),
                device=codes.device,
                dtype=torch.float32,
            )
            bias = _round_ste(conv.bias / bias_scale)
        if conv.padding[0]:
            padded = F.pad(
                codes,
                (conv.padding[1], conv.padding[1], conv.padding[0], conv.padding[0]),
                mode="replicate",
            )
        else:
            padded = codes
        accumulator = F.conv2d(
            padded,
            qweight,
            bias,
            conv.stride,
            0,
            conv.dilation,
            conv.groups,
        )
        multipliers = torch.as_tensor(
            row["multipliers"], device=codes.device, dtype=torch.float32
        ).reshape(1, -1, 1, 1)
        shifts = torch.as_tensor(row["shifts"], device=codes.device)
        quantized = _round_shift_away_ste(accumulator * multipliers, shifts)
        quantized = torch.clamp(quantized, -128.0, 127.0)
        return F.relu(quantized) if relu else quantized

    def forward_codes(
        self, rgb01: Tensor, collect: bool = False
    ) -> tuple[Tensor, dict[str, Tensor]]:
        layers: dict[str, Tensor] = {}

        def record(name: str, value: Tensor) -> Tensor:
            if collect:
                layers[name] = value
            return value

        clipped = torch.clamp(rgb01, 0.0, 1.0)
        code_float = clipped * 255.0
        value = code_float + (torch.round(code_float) - code_float).detach() - 128.0
        value = record("encoder1.conv3x3_s2", self._conv("encoder1.conv3x3_s2", value, True))
        value = record("encoder2.conv3x3_s2", self._conv("encoder2.conv3x3_s2", value, True))
        for block_index in range(3):
            skip = value
            value = record(
                f"res{block_index}.expand1x1",
                self._conv(f"res{block_index}.expand1x1", value, True),
            )
            value = record(
                f"res{block_index}.depthwise3x3",
                self._conv(f"res{block_index}.depthwise3x3", value, True),
            )
            value = record(
                f"res{block_index}.project1x1",
                self._conv(f"res{block_index}.project1x1", value, False),
            )
            value = torch.clamp(value + skip, -128.0, 127.0)
            value = record(f"res{block_index}.add_relu", F.relu(value))
        value = F.interpolate(value, scale_factor=2, mode="nearest")
        if collect:
            layers["decoder1.upsample2"] = value
        value = record(
            "decoder1.depthwise3x3", self._conv("decoder1.depthwise3x3", value, True)
        )
        value = record(
            "decoder1.pointwise1x1", self._conv("decoder1.pointwise1x1", value, True)
        )
        value = F.interpolate(value, scale_factor=2, mode="nearest")
        if collect:
            layers["decoder2.upsample2"] = value
        value = record(
            "decoder2.depthwise3x3", self._conv("decoder2.depthwise3x3", value, True)
        )
        value = record(
            "decoder2.pointwise1x1", self._conv("decoder2.pointwise1x1", value, True)
        )
        value = record(
            "output.conv3x3", self._conv("output.conv3x3", value, False)
        )
        return value, layers

    def forward(self, rgb01: Tensor) -> Tensor:
        codes, _ = self.forward_codes(rgb01)
        return torch.clamp(codes + 128.0, 0.0, 255.0) / 255.0


def load_qat_checkpoint(
    checkpoint_path: Path, device: str | torch.device = "cpu"
) -> QATMicroStyle24:
    """Reconstruct an executable QAT model from the safe tensor checkpoint."""
    from microstyle_model import MicroStyle24

    checkpoint = torch.load(checkpoint_path, map_location=device, weights_only=True)
    model = fuse_batch_norms(MicroStyle24()).to(device)
    model.load_state_dict(checkpoint["model_state"], strict=True)
    weight_scales = {
        name: np.asarray(values, dtype=np.float64)
        for name, values in checkpoint["weight_scales"].items()
    }
    qat = QATMicroStyle24(
        model, checkpoint["activation_scales"], weight_scales
    ).to(device)
    return qat.eval()


def _quantized_arrays(
    qat: QATMicroStyle24, name: str
) -> tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray]:
    conv = convolution_modules(qat.model)[name]
    row = qat.quant_parameters[name]
    weight_scale = np.asarray(row["weight_scales"], dtype=np.float64)
    weight = conv.weight.detach().cpu().numpy().astype(np.float64)
    qweight = np.clip(
        np.floor(weight / weight_scale.reshape(-1, 1, 1, 1) + 0.5), -127, 127
    )
    # Correct negative rounding to nearest, away from zero only matters at
    # exact half; np.rint would use ties-to-even and must not be used here.
    scaled_weight = weight / weight_scale.reshape(-1, 1, 1, 1)
    qweight = np.sign(scaled_weight) * np.floor(np.abs(scaled_weight) + 0.5)
    qweight = np.clip(qweight, -127, 127).astype(np.int8)
    bias = conv.bias.detach().cpu().numpy().astype(np.float64)
    bias_scale = weight_scale * float(row["input_scale"])
    scaled_bias = bias / bias_scale
    qbias = np.sign(scaled_bias) * np.floor(np.abs(scaled_bias) + 0.5)
    if np.any(qbias < -(1 << 31)) or np.any(qbias > (1 << 31) - 1):
        raise OverflowError(f"{name} folded bias exceeds signed32")
    return (
        qweight,
        qbias.astype(np.int32),
        np.asarray(row["multipliers"], dtype=np.int32),
        np.asarray(row["shifts"], dtype=np.uint8),
    )


def export_quantized_artifact(
    qat: QATMicroStyle24,
    output_dir: Path,
    metadata: dict[str, object],
    width: int = 640,
    height: int = 480,
) -> dict[str, object]:
    """Write descriptors, the exact 16,896-byte arena and audit metadata."""
    descriptors, layout = build_layout(width, height)
    if layout["descriptor_count"] != 22 or layout["parameter_arena_bytes"] != 16_896:
        raise RuntimeError("frozen descriptor/arena ABI changed")
    output_dir.mkdir(parents=True, exist_ok=True)
    arena = bytearray(layout["parameter_arena_bytes"])
    parameter_rows = {row["name"]: row for row in layout["parameter_layout"]}
    npz_arrays: dict[str, np.ndarray] = {}
    quant_layers: list[dict[str, object]] = []
    specs = {spec.name: spec for spec in layer_specs(width, height)}

    for name in CONV_NAMES:
        qweight, qbias, multipliers, shifts = _quantized_arrays(qat, name)
        parameter = parameter_rows[name]
        if qweight.size != parameter["weight_bytes"]:
            raise RuntimeError(f"{name} weight size disagrees with frozen layout")
        offsets_and_payloads = (
            (parameter["weight_offset"], qweight.tobytes(order="C")),
            (parameter["bias_offset"], qbias.astype("<i4").tobytes()),
            (parameter["multiplier_offset"], multipliers.astype("<i4").tobytes()),
            (parameter["shift_offset"], shifts.tobytes()),
        )
        for offset, payload in offsets_and_payloads:
            arena[offset : offset + len(payload)] = payload
        key = name.replace(".", "__")
        npz_arrays[f"{key}__weight"] = qweight
        npz_arrays[f"{key}__bias"] = qbias
        npz_arrays[f"{key}__multiplier"] = multipliers
        npz_arrays[f"{key}__shift"] = shifts
        spec = specs[name]
        quant_layers.append(
            {
                "name": name,
                "opcode": spec.opcode,
                "activation": spec.activation,
                "stride": spec.stride,
                "groups": int(convolution_modules(qat.model)[name].groups),
                "weight_shape": list(qweight.shape),
                "input_scale": float(qat.quant_parameters[name]["input_scale"]),
                "output_scale": float(qat.quant_parameters[name]["output_scale"]),
                "weight_scales": np.asarray(
                    qat.quant_parameters[name]["weight_scales"]
                ).astype(float).tolist(),
                "weight_offset": parameter["weight_offset"],
                "weight_bytes": parameter["weight_bytes"],
                "bias_offset": parameter["bias_offset"],
                "bias_bytes": parameter["bias_bytes"],
                "multiplier_offset": parameter["multiplier_offset"],
                "multiplier_bytes": parameter["multiplier_bytes"],
                "shift_offset": parameter["shift_offset"],
                "shift_bytes": parameter["shift_bytes"],
                "multiplier_min": int(multipliers.min()),
                "multiplier_max": int(multipliers.max()),
                "shift_min": int(shifts.min()),
                "shift_max": int(shifts.max()),
                "bias_min": int(qbias.min()),
                "bias_max": int(qbias.max()),
            }
        )

    descriptor_payload = b"".join(descriptor.pack() for descriptor in descriptors)
    (output_dir / "descriptors.bin").write_bytes(descriptor_payload)
    (output_dir / "parameter_arena.bin").write_bytes(arena)
    np.savez(output_dir / "weights_int8.npz", **npz_arrays)
    manifest: dict[str, object] = dict(layout)
    manifest.update(
        {
            "schema_version": 2,
            "artifact_role": "functional_qat_checkpoint_not_final_quality",
            "trained": True,
            "warning": (
                "Functionally trained/QAT checkpoint; visual convergence and "
                "competition-quality style are not claimed."
            ),
            "activation_format": "s8 symmetric, ReLU clamps to 0..127",
            "weight_format": "per-output-channel symmetric s8",
            "bias_format": "s32 accumulator units",
            "requant_format": "signed18 multiplier, shift 0..47, midpoint away from zero",
            "residual_contract": "shared scale and saturating s8 add before ReLU",
            "descriptor_file": "descriptors.bin",
            "parameter_file": "parameter_arena.bin",
            "weights_debug_file": "weights_int8.npz",
            "quantized_layers": quant_layers,
            "training": metadata,
        }
    )
    (output_dir / "manifest.json").write_text(
        json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )
    return manifest


def _round_shift_away_int(values: np.ndarray, shifts: np.ndarray) -> np.ndarray:
    values = np.asarray(values, dtype=np.int64)
    output = np.empty_like(values)
    for channel, shift_value in enumerate(np.asarray(shifts).reshape(-1)):
        shift = int(shift_value)
        source = values[..., channel]
        if shift == 0:
            output[..., channel] = source
        else:
            magnitude = np.abs(source)
            rounded = (magnitude + (1 << (shift - 1))) >> shift
            output[..., channel] = np.where(source < 0, -rounded, rounded)
    return output


def _read_layer_arrays(
    arena: bytes, row: dict[str, object]
) -> tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray]:
    shape = tuple(int(value) for value in row["weight_shape"])
    count = int(np.prod(shape))
    weight_offset = int(row["weight_offset"])
    weight = np.frombuffer(arena, dtype=np.int8, count=count, offset=weight_offset).copy()
    weight = weight.reshape(shape)
    channels = shape[0]
    bias = np.frombuffer(
        arena, dtype="<i4", count=channels, offset=int(row["bias_offset"])
    ).astype(np.int64)
    multiplier = np.frombuffer(
        arena, dtype="<i4", count=channels, offset=int(row["multiplier_offset"])
    ).astype(np.int64)
    shift = np.frombuffer(
        arena, dtype=np.uint8, count=channels, offset=int(row["shift_offset"])
    ).copy()
    return weight, bias, multiplier, shift


def _integer_conv(
    value: np.ndarray,
    weight: np.ndarray,
    bias: np.ndarray,
    multiplier: np.ndarray,
    shift: np.ndarray,
    stride: int,
    groups: int,
    activation: int,
) -> np.ndarray:
    source = np.asarray(value, dtype=np.int64)
    if weight.shape[2:] == (3, 3):
        padded = np.pad(source, ((1, 1), (1, 1), (0, 0)), mode="edge")
        windows = np.lib.stride_tricks.sliding_window_view(
            padded, (3, 3), axis=(0, 1)
        )[::stride, ::stride]
        if groups == source.shape[2] and weight.shape[1] == 1:
            accumulator = np.einsum(
                "hwcij,cij->hwc", windows, weight[:, 0].astype(np.int64), optimize=True
            )
        else:
            accumulator = np.einsum(
                "hwcij,ocij->hwo", windows, weight.astype(np.int64), optimize=True
            )
    elif weight.shape[2:] == (1, 1):
        accumulator = np.einsum(
            "hwc,oc->hwo", source, weight[:, :, 0, 0].astype(np.int64), optimize=True
        )
    else:
        raise ValueError(f"unsupported exported kernel shape {weight.shape}")
    accumulator += bias.reshape(1, 1, -1)
    if np.any(accumulator < -(1 << 31)) or np.any(accumulator > (1 << 31) - 1):
        raise OverflowError("MicroStyle accumulator exceeded signed32")
    product = accumulator * multiplier.reshape(1, 1, -1)
    quantized = _round_shift_away_int(product, shift)
    quantized = np.clip(quantized, -128, 127)
    if activation == 1:
        quantized = np.maximum(quantized, 0)
    return quantized.astype(np.int8)


def integer_infer_rgb(
    rgb_u8: np.ndarray, artifact_dir: Path, collect: bool = False
) -> tuple[np.ndarray, dict[str, np.ndarray]]:
    """Run the complete 22-stage exported network with integer NumPy ops."""
    image = np.asarray(rgb_u8, dtype=np.uint8)
    if image.ndim != 3 or image.shape[2] != 3:
        raise ValueError("integer MicroStyle input must be HxWx3 uint8")
    if image.shape[0] % 4 or image.shape[1] % 4:
        raise ValueError("integer MicroStyle dimensions must be divisible by four")
    manifest = json.loads((artifact_dir / "manifest.json").read_text(encoding="utf-8"))
    arena = (artifact_dir / str(manifest["parameter_file"])).read_bytes()
    if len(arena) != int(manifest["parameter_arena_bytes"]):
        raise ValueError("parameter arena length disagrees with manifest")
    rows = {row["name"]: row for row in manifest["quantized_layers"]}
    layers: dict[str, np.ndarray] = {}

    def conv(name: str, source: np.ndarray) -> np.ndarray:
        row = rows[name]
        result = _integer_conv(
            source,
            *_read_layer_arrays(arena, row),
            int(row["stride"]),
            int(row["groups"]),
            int(row["activation"]),
        )
        if collect:
            layers[name] = result.copy()
        return result

    value = (image.astype(np.int16) - 128).astype(np.int8)
    value = conv("encoder1.conv3x3_s2", value)
    value = conv("encoder2.conv3x3_s2", value)
    for block_index in range(3):
        skip = value.astype(np.int16)
        value = conv(f"res{block_index}.expand1x1", value)
        value = conv(f"res{block_index}.depthwise3x3", value)
        value = conv(f"res{block_index}.project1x1", value)
        value = np.clip(value.astype(np.int16) + skip, -128, 127)
        value = np.maximum(value, 0).astype(np.int8)
        if collect:
            layers[f"res{block_index}.add_relu"] = value.copy()
    value = np.repeat(np.repeat(value, 2, axis=0), 2, axis=1)
    if collect:
        layers["decoder1.upsample2"] = value.copy()
    value = conv("decoder1.depthwise3x3", value)
    value = conv("decoder1.pointwise1x1", value)
    value = np.repeat(np.repeat(value, 2, axis=0), 2, axis=1)
    if collect:
        layers["decoder2.upsample2"] = value.copy()
    value = conv("decoder2.depthwise3x3", value)
    value = conv("decoder2.pointwise1x1", value)
    value = conv("output.conv3x3", value)
    output = np.clip(value.astype(np.int16) + 128, 0, 255).astype(np.uint8)
    if collect:
        layers["output.s8_to_rgb"] = output.copy()
    return output, layers

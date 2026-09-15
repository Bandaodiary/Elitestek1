"""Hardware-oriented MicroStyle-24 reference network.

This file freezes the final network topology and tensor names.  The seeded
initialization exported by this module remains an explicitly untrained layout
artifact.  ``train_microstyle_qat.py`` separately produces the optimized,
BN-folded functional checkpoint and the bit-exact R1 parameter arena without
changing this topology or the surrounding video-system ABI.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np
import torch
from torch import Tensor, nn
from torch.nn import functional as F


class InvertedResidual(nn.Module):
    def __init__(self, channels: int = 24, expansion: int = 48) -> None:
        super().__init__()
        self.expand = nn.Conv2d(channels, expansion, 1, bias=False)
        self.expand_norm = nn.BatchNorm2d(expansion)
        self.depthwise = nn.Conv2d(
            expansion, expansion, 3, padding=1, padding_mode="replicate",
            groups=expansion, bias=False
        )
        self.depthwise_norm = nn.BatchNorm2d(expansion)
        self.project = nn.Conv2d(expansion, channels, 1, bias=False)
        self.project_norm = nn.BatchNorm2d(channels)
        self.activation = nn.ReLU(inplace=False)

    def forward(self, value: Tensor) -> Tensor:
        residual = value
        value = self.activation(self.expand_norm(self.expand(value)))
        value = self.activation(self.depthwise_norm(self.depthwise(value)))
        value = self.project_norm(self.project(value))
        return self.activation(value + residual)


class UpsampleDepthwisePointwise(nn.Module):
    def __init__(self, in_channels: int, out_channels: int) -> None:
        super().__init__()
        self.depthwise = nn.Conv2d(
            in_channels, in_channels, 3, padding=1, padding_mode="replicate",
            groups=in_channels, bias=False
        )
        self.depthwise_norm = nn.BatchNorm2d(in_channels)
        self.pointwise = nn.Conv2d(in_channels, out_channels, 1, bias=False)
        self.pointwise_norm = nn.BatchNorm2d(out_channels)
        self.activation = nn.ReLU(inplace=False)

    def forward(self, value: Tensor) -> Tensor:
        value = F.interpolate(value, scale_factor=2, mode="nearest")
        value = self.activation(self.depthwise_norm(self.depthwise(value)))
        return self.activation(self.pointwise_norm(self.pointwise(value)))


class MicroStyle24(nn.Module):
    """12,212-weight style-transfer generator for 640x480 RGB frames."""

    def __init__(self) -> None:
        super().__init__()
        self.encoder1 = nn.Conv2d(
            3, 12, 3, stride=2, padding=1, padding_mode="replicate", bias=False
        )
        self.encoder1_norm = nn.BatchNorm2d(12)
        self.encoder2 = nn.Conv2d(
            12, 24, 3, stride=2, padding=1, padding_mode="replicate", bias=False
        )
        self.encoder2_norm = nn.BatchNorm2d(24)
        self.activation = nn.ReLU(inplace=False)
        self.residual = nn.Sequential(*(InvertedResidual() for _ in range(3)))
        self.decoder1 = UpsampleDepthwisePointwise(24, 16)
        self.decoder2 = UpsampleDepthwisePointwise(16, 8)
        self.output = nn.Conv2d(
            8, 3, 3, padding=1, padding_mode="replicate", bias=False
        )
        self.output_norm = nn.BatchNorm2d(3)

    def forward(self, rgb01: Tensor) -> Tensor:
        if (rgb01.shape[-1] % 4) or (rgb01.shape[-2] % 4):
            raise ValueError("MicroStyle-24 width and height must be multiples of four")
        # Straight-through code quantization freezes the RTL input grid:
        # q_s8 = round(rgb01*255)-128, scale = 1/128.
        clipped = torch.clamp(rgb01, 0.0, 1.0)
        code_float = clipped * 255.0
        code = code_float + (torch.round(code_float) - code_float).detach()
        value = (code - 128.0) / 128.0
        value = self.activation(self.encoder1_norm(self.encoder1(value)))
        value = self.activation(self.encoder2_norm(self.encoder2(value)))
        value = self.residual(value)
        value = self.decoder1(value)
        value = self.decoder2(value)
        value = torch.clamp(self.output_norm(self.output(value)), -1.0, 127.0 / 128.0)
        output_code_float = value * 128.0 + 128.0
        output_code = output_code_float + (
            torch.round(output_code_float) - output_code_float
        ).detach()
        return torch.clamp(output_code, 0.0, 255.0) / 255.0


def layer_budget(width: int = 640, height: int = 480) -> list[dict[str, int | str]]:
    if (width % 4) or (height % 4):
        raise ValueError("MicroStyle-24 budget requires width and height divisible by four")
    def entry(name: str, w: int, h: int, cin: int, cout: int, kernel: int) -> dict[str, int | str]:
        return {
            "name": name,
            "width": w,
            "height": h,
            "in_channels": cin,
            "out_channels": cout,
            "kernel": kernel,
            "weights": cin * cout * kernel * kernel,
            "macs": w * h * cin * cout * kernel * kernel,
        }

    rows: list[dict[str, int | str]] = []
    rows.append(entry("encoder1.conv3x3_s2", width // 2, height // 2, 3, 12, 3))
    rows.append(entry("encoder2.conv3x3_s2", width // 4, height // 4, 12, 24, 3))
    for block in range(3):
        w, h = width // 4, height // 4
        rows.append(entry(f"res{block}.expand1x1", w, h, 24, 48, 1))
        row = entry(f"res{block}.depthwise3x3", w, h, 1, 48, 3)
        row["weights"] = 48 * 3 * 3
        row["macs"] = w * h * 48 * 3 * 3
        rows.append(row)
        rows.append(entry(f"res{block}.project1x1", w, h, 48, 24, 1))
    w1, h1 = width // 2, height // 2
    row = entry("decoder1.depthwise3x3", w1, h1, 1, 24, 3)
    row["weights"] = 24 * 3 * 3
    row["macs"] = w1 * h1 * 24 * 3 * 3
    rows.extend((row, entry("decoder1.pointwise1x1", w1, h1, 24, 16, 1)))
    row = entry("decoder2.depthwise3x3", width, height, 1, 16, 3)
    row["weights"] = 16 * 3 * 3
    row["macs"] = width * height * 16 * 3 * 3
    rows.extend((row, entry("decoder2.pointwise1x1", width, height, 16, 8, 1)))
    rows.append(entry("output.conv3x3", width, height, 8, 3, 3))
    return rows


def export_untrained_int8_skeleton(model: nn.Module, directory: Path) -> None:
    """Export tensor layout for integration tests, never as competition weights."""
    directory.mkdir(parents=True, exist_ok=True)
    arrays: dict[str, np.ndarray] = {}
    tensors: list[dict[str, object]] = []
    for name, parameter in model.state_dict().items():
        source = parameter.detach().cpu().numpy().astype(np.float32)
        peak = float(np.max(np.abs(source)))
        scale = peak / 127.0 if peak else 1.0
        quantized = np.clip(np.rint(source / scale), -127, 127).astype(np.int8)
        key = name.replace(".", "__")
        arrays[key] = quantized
        tensors.append({"name": name, "key": key, "shape": list(source.shape), "scale": scale})
    np.savez(directory / "weights_untrained_int8.npz", **arrays)
    manifest = {
        "schema_version": 1,
        "artifact_role": "layout_only_untrained",
        "model": "MicroStyle-24",
        "trained": False,
        "warning": "Topology/layout artifact only; train and QAT before FPGA use.",
        "activation": "signed-int8 target",
        "accumulator": "signed-int32",
        "tensors": tensors,
    }
    (directory / "manifest_untrained.json").write_text(
        json.dumps(manifest, indent=2) + "\n", encoding="utf-8"
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--export-untrained", type=Path)
    parser.add_argument("--smoke-width", type=int, default=64)
    parser.add_argument("--smoke-height", type=int, default=48)
    args = parser.parse_args()

    torch.manual_seed(2026)
    model = MicroStyle24().eval()
    training_parameters = sum(parameter.numel() for parameter in model.parameters())
    budget = layer_budget()
    weights = sum(int(row["weights"]) for row in budget)
    macs = sum(int(row["macs"]) for row in budget)
    if weights != 12_212 or training_parameters != 13_138 or macs != 428_236_800:
        raise RuntimeError(
            "frozen budget mismatch: "
            f"trainable={training_parameters}, conv_weights={weights}, macs={macs}"
        )
    with torch.no_grad():
        sample = torch.linspace(
            0.0, 1.0, args.smoke_width * args.smoke_height * 3, dtype=torch.float32
        ).reshape(1, 3, args.smoke_height, args.smoke_width)
        output = model(sample)
    if output.shape != sample.shape or not torch.isfinite(output).all():
        raise RuntimeError("MicroStyle-24 smoke inference failed")
    if args.export_untrained is not None:
        export_untrained_int8_skeleton(model, args.export_untrained)
    print(
        "MICROSTYLE24_OK",
        json.dumps(
            {
                "convolution_weights": weights,
                "training_parameters_with_foldable_bn": training_parameters,
                "macs_per_640x480_frame": macs,
                "gmac_per_second_at_15fps": macs * 15 / 1e9,
                "smoke_shape": list(output.shape),
            },
            sort_keys=True,
        ),
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

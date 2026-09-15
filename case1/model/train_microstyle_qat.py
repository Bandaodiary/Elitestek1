"""Train and export a reproducible functional MicroStyle-24 QAT checkpoint.

The objective is intentionally lightweight and self-contained: content is
preserved at low spatial frequencies while fixed RGB/Sobel/Laplacian Gram and
colour-statistic losses move the output toward one public-domain style image.
This is a real optimized feed-forward style model, but the short default run
is an engineering checkpoint for RTL integration rather than a claim of final
artistic convergence.
"""

from __future__ import annotations

import argparse
import json
import random
from pathlib import Path
import time

import numpy as np
from PIL import Image
import torch
from torch import Tensor, nn
from torch.nn import functional as F

from microstyle_model import MicroStyle24
from microstyle_quant import (
    CONV_NAMES,
    QATMicroStyle24,
    calibrate_activation_scales,
    convolution_modules,
    export_quantized_artifact,
    fuse_batch_norms,
    integer_infer_rgb,
)


STYLE_SOURCE_PAGE = (
    "https://commons.wikimedia.org/wiki/"
    "File:TheStarryNightByVincentVanGogh.jpg"
)
STYLE_LICENSE = "Public Domain Mark 1.0 / public-domain painting"


def configure_reproducibility(seed: int) -> None:
    random.seed(seed)
    np.random.seed(seed)
    torch.manual_seed(seed)
    if torch.cuda.is_available():
        torch.cuda.manual_seed_all(seed)
    torch.backends.cudnn.benchmark = False
    torch.backends.cudnn.deterministic = True
    torch.use_deterministic_algorithms(True)


def load_image(path: Path) -> Tensor:
    with Image.open(path) as image:
        rgb = np.asarray(image.convert("RGB"), dtype=np.uint8).copy()
    return torch.from_numpy(rgb.transpose(2, 0, 1)).float() / 255.0


def discover_content(directory: Path, style_path: Path) -> list[Path]:
    suffixes = {".png", ".jpg", ".jpeg", ".bmp", ".tif", ".tiff"}
    style_resolved = style_path.resolve()
    rows = [
        path
        for path in sorted(directory.iterdir())
        if path.is_file()
        and path.suffix.lower() in suffixes
        and path.resolve() != style_resolved
    ]
    if not rows:
        raise ValueError(f"no content images found in {directory}")
    return rows


class PatchStream:
    def __init__(self, images: list[Tensor], seed: int) -> None:
        self.images = images
        self.rng = random.Random(seed)

    def batch(self, batch_size: int, patch: int, device: torch.device) -> Tensor:
        rows: list[Tensor] = []
        for _ in range(batch_size):
            source = self.images[self.rng.randrange(len(self.images))]
            _, height, width = source.shape
            if min(height, width) < patch:
                scale = patch / min(height, width)
                target_h = max(patch, int(round(height * scale)))
                target_w = max(patch, int(round(width * scale)))
                source = F.interpolate(
                    source.unsqueeze(0),
                    size=(target_h, target_w),
                    mode="bilinear",
                    align_corners=False,
                )[0]
                _, height, width = source.shape
            top = self.rng.randrange(height - patch + 1)
            left = self.rng.randrange(width - patch + 1)
            crop = source[:, top : top + patch, left : left + patch]
            if self.rng.random() < 0.5:
                crop = torch.flip(crop, dims=(2,))
            rows.append(crop)
        return torch.stack(rows).to(device)


def _fixed_features(image: Tensor) -> Tensor:
    dtype, device = image.dtype, image.device
    gray = (
        image[:, 0:1] * 0.299
        + image[:, 1:2] * 0.587
        + image[:, 2:3] * 0.114
    )
    sobel_x = torch.tensor(
        [[-1.0, 0.0, 1.0], [-2.0, 0.0, 2.0], [-1.0, 0.0, 1.0]],
        dtype=dtype,
        device=device,
    ).reshape(1, 1, 3, 3) / 4.0
    sobel_y = sobel_x.transpose(2, 3)
    laplace = torch.tensor(
        [[0.0, 1.0, 0.0], [1.0, -4.0, 1.0], [0.0, 1.0, 0.0]],
        dtype=dtype,
        device=device,
    ).reshape(1, 1, 3, 3) / 4.0
    padded = F.pad(gray, (1, 1, 1, 1), mode="replicate")
    gx = F.conv2d(padded, sobel_x)
    gy = F.conv2d(padded, sobel_y)
    lap = F.conv2d(padded, laplace)
    return torch.cat((image, gx, gy, lap), dim=1)


def _gram(features: Tensor) -> Tensor:
    flattened = features.flatten(2)
    return torch.bmm(flattened, flattened.transpose(1, 2)) / flattened.shape[2]


def style_targets(style: Tensor) -> dict[str, list[Tensor] | Tensor]:
    grams: list[Tensor] = []
    value = style
    for _ in range(3):
        grams.append(_gram(_fixed_features(value)).mean(dim=0, keepdim=True).detach())
        value = F.avg_pool2d(value, 2)
    mean = style.mean(dim=(2, 3), keepdim=True).detach()
    std = style.std(dim=(2, 3), keepdim=True, unbiased=False).detach()
    # A deterministic luminance-ordered palette gives the tiny model a stable
    # supervised stylization target.  It avoids the high-frequency noise that
    # an under-converged Gram-only model can exploit while still deriving every
    # target colour from the selected style painting.
    pixels = style.permute(0, 2, 3, 1).reshape(-1, 3)
    luminance = (
        pixels[:, 0] * 0.299 + pixels[:, 1] * 0.587 + pixels[:, 2] * 0.114
    )
    boundaries = torch.quantile(
        luminance, torch.linspace(0.0, 1.0, 7, device=style.device)
    )
    palette_rows: list[Tensor] = []
    palette_luma: list[Tensor] = []
    for index in range(6):
        if index == 5:
            mask = (luminance >= boundaries[index]) & (luminance <= boundaries[index + 1])
        else:
            mask = (luminance >= boundaries[index]) & (luminance < boundaries[index + 1])
        palette_rows.append(pixels[mask].mean(dim=0))
        palette_luma.append(luminance[mask].mean())
    return {
        "grams": grams,
        "mean": mean,
        "std": std,
        "palette": torch.stack(palette_rows).detach(),
        "palette_luma": torch.stack(palette_luma).detach(),
    }


def palette_target(
    content: Tensor, targets: dict[str, list[Tensor] | Tensor]
) -> Tensor:
    palette = targets["palette"]
    palette_luma = targets["palette_luma"]
    assert isinstance(palette, Tensor) and isinstance(palette_luma, Tensor)
    luminance = (
        content[:, 0:1] * 0.299
        + content[:, 1:2] * 0.587
        + content[:, 2:3] * 0.114
    )
    distances = luminance.unsqueeze(1) - palette_luma.reshape(1, -1, 1, 1, 1)
    selection = torch.softmax(-(distances / 0.11) ** 2, dim=1)
    palette_image = (
        selection * palette.reshape(1, -1, 3, 1, 1)
    ).sum(dim=1)
    smoothed = F.avg_pool2d(
        F.pad(content, (2, 2, 2, 2), mode="replicate"), 5, stride=1
    )
    detail = content - smoothed
    return torch.clamp(0.72 * palette_image + 0.28 * content + 0.10 * detail, 0.0, 1.0)


def objective(
    output: Tensor,
    content: Tensor,
    targets: dict[str, list[Tensor] | Tensor],
) -> tuple[Tensor, dict[str, Tensor]]:
    output_low = F.avg_pool2d(output, 4)
    content_low = F.avg_pool2d(content, 4)
    content_loss = F.l1_loss(output_low, content_low)

    output_features = _fixed_features(output)
    content_features = _fixed_features(content)
    edge_loss = F.l1_loss(output_features[:, 3:5], content_features[:, 3:5])
    supervised_target = palette_target(content, targets)
    target_loss = F.l1_loss(output, supervised_target)

    gram_loss = output.new_zeros(())
    value = output
    gram_targets = targets["grams"]
    assert isinstance(gram_targets, list)
    for target in gram_targets:
        observed = _gram(_fixed_features(value))
        gram_loss = gram_loss + F.l1_loss(observed, target.expand_as(observed))
        value = F.avg_pool2d(value, 2)

    mean = output.mean(dim=(2, 3), keepdim=True)
    std = output.std(dim=(2, 3), keepdim=True, unbiased=False)
    target_mean = targets["mean"]
    target_std = targets["std"]
    assert isinstance(target_mean, Tensor) and isinstance(target_std, Tensor)
    colour_loss = F.l1_loss(mean, target_mean.expand_as(mean)) + F.l1_loss(
        std, target_std.expand_as(std)
    )
    tv_loss = (
        (output[:, :, 1:, :] - output[:, :, :-1, :]).abs().mean()
        + (output[:, :, :, 1:] - output[:, :, :, :-1]).abs().mean()
    )
    total = (
        1.2 * content_loss
        + 0.40 * edge_loss
        + 1.5 * gram_loss
        + 1.0 * colour_loss
        + 4.0 * target_loss
        + 0.05 * tv_loss
    )
    return total, {
        "total": total,
        "content": content_loss,
        "edge": edge_loss,
        "target": target_loss,
        "gram": gram_loss,
        "colour": colour_loss,
        "tv": tv_loss,
    }


def _float_terms(rows: dict[str, Tensor]) -> dict[str, float]:
    return {name: float(value.detach().cpu()) for name, value in rows.items()}


def train_phase(
    model: nn.Module,
    optimizer: torch.optim.Optimizer,
    stream: PatchStream,
    targets: dict[str, list[Tensor] | Tensor],
    steps: int,
    batch_size: int,
    patch: int,
    device: torch.device,
    label: str,
) -> tuple[dict[str, float], dict[str, float], list[dict[str, float | int]]]:
    model.train()
    first: dict[str, float] | None = None
    last: dict[str, float] | None = None
    trace: list[dict[str, float | int]] = []
    for step in range(steps):
        content = stream.batch(batch_size, patch, device)
        optimizer.zero_grad(set_to_none=True)
        output = model(content)
        loss, terms = objective(output, content, targets)
        if not torch.isfinite(loss):
            raise FloatingPointError(f"{label} loss became non-finite at step {step}")
        loss.backward()
        torch.nn.utils.clip_grad_norm_(model.parameters(), 5.0)
        optimizer.step()
        current = _float_terms(terms)
        if first is None:
            first = current
        last = current
        if step == 0 or step + 1 == steps or (step + 1) % max(1, steps // 5) == 0:
            trace.append({"step": step + 1, **current})
            print(
                f"{label.upper()} step={step + 1}/{steps} "
                f"loss={current['total']:.6f} style={current['gram']:.6f} "
                f"target={current['target']:.6f} content={current['content']:.6f}"
            )
    if first is None or last is None:
        raise ValueError(f"{label} requires at least one training step")
    return first, last, trace


def _resize_tensor(image: Tensor, size: int, device: torch.device) -> Tensor:
    return F.interpolate(
        image.unsqueeze(0).to(device),
        size=(size, size),
        mode="bilinear",
        align_corners=False,
    )


def _image_u8(tensor: Tensor) -> np.ndarray:
    value = tensor.detach().cpu().clamp(0.0, 1.0)[0]
    return torch.round(value * 255.0).byte().permute(1, 2, 0).numpy()


def _save_rgb(path: Path, image: np.ndarray) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    Image.fromarray(np.asarray(image, dtype=np.uint8), mode="RGB").save(path)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--content-dir", type=Path, default=Path("assets/images"))
    parser.add_argument(
        "--style",
        type=Path,
        default=Path("assets/styles/starry_night_public_domain.jpg"),
    )
    parser.add_argument(
        "--artifact-dir", type=Path, default=Path("model/microstyle24_starry_functional")
    )
    parser.add_argument(
        "--output-dir", type=Path, default=Path("outputs/microstyle_qat")
    )
    parser.add_argument("--float-steps", type=int, default=240)
    parser.add_argument("--qat-steps", type=int, default=80)
    parser.add_argument("--patch", type=int, default=64)
    parser.add_argument("--batch-size", type=int, default=2)
    parser.add_argument("--seed", type=int, default=20260824)
    parser.add_argument("--device", choices=("auto", "cpu", "cuda"), default="auto")
    args = parser.parse_args()

    if args.patch < 16 or args.patch % 4:
        raise ValueError("patch must be at least 16 and divisible by four")
    if args.float_steps <= 0 or args.qat_steps <= 0 or args.batch_size <= 0:
        raise ValueError("training steps and batch size must be positive")
    if not args.style.is_file():
        raise FileNotFoundError(f"style image missing: {args.style}")
    configure_reproducibility(args.seed)
    if args.device == "auto":
        device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    else:
        device = torch.device(args.device)
    if device.type == "cuda" and not torch.cuda.is_available():
        raise RuntimeError("CUDA was requested but is unavailable")

    content_paths = discover_content(args.content_dir, args.style)
    content_images = [load_image(path) for path in content_paths]
    style = _resize_tensor(load_image(args.style), 256, device)
    targets = style_targets(style)
    stream = PatchStream(content_images, args.seed + 1)

    start_time = time.perf_counter()
    model = MicroStyle24().to(device)
    initial_weights = torch.cat(
        [module.weight.detach().flatten().cpu() for module in convolution_modules(model).values()]
    )
    float_optimizer = torch.optim.Adam(model.parameters(), lr=1.5e-3)
    float_first, float_last, float_trace = train_phase(
        model,
        float_optimizer,
        stream,
        targets,
        args.float_steps,
        args.batch_size,
        args.patch,
        device,
        "float",
    )

    model.eval()
    fused = fuse_batch_norms(model).to(device)
    calibration_stream = PatchStream(content_images, args.seed + 2)
    calibration_batches = [
        calibration_stream.batch(args.batch_size, args.patch, device) for _ in range(8)
    ]
    activation_scales = calibrate_activation_scales(fused, calibration_batches)
    qat = QATMicroStyle24(fused, activation_scales).to(device)
    qat_stream = PatchStream(content_images, args.seed + 3)
    qat_optimizer = torch.optim.Adam(qat.parameters(), lr=1.0e-4)
    qat_first, qat_last, qat_trace = train_phase(
        qat,
        qat_optimizer,
        qat_stream,
        targets,
        args.qat_steps,
        args.batch_size,
        args.patch,
        device,
        "qat",
    )
    qat.eval()

    final_weights = torch.cat(
        [module.weight.detach().flatten().cpu() for module in convolution_modules(qat.model).values()]
    )
    weight_delta_l2 = float(torch.linalg.vector_norm(final_weights - initial_weights))
    if not weight_delta_l2 > 0.0:
        raise RuntimeError("training did not change convolution weights")

    preview_input = _resize_tensor(content_images[0], 128, device)
    with torch.no_grad():
        preview_output = qat(preview_input)
        preview_supervised_target = palette_target(preview_input, targets)
        _, preview_terms = objective(preview_output, preview_input, targets)
    preview_input_u8 = _image_u8(preview_input)
    preview_output_u8 = _image_u8(preview_output)
    output_change_mae = float(
        np.mean(np.abs(preview_output_u8.astype(np.int16) - preview_input_u8.astype(np.int16)))
    )
    output_saturation = float(
        np.mean((preview_output_u8 == 0) | (preview_output_u8 == 255))
    )

    elapsed = time.perf_counter() - start_time
    training_metadata: dict[str, object] = {
        "status": "functional_checkpoint_not_final_visual_convergence",
        "seed": args.seed,
        "device": str(device),
        "torch_version": str(torch.__version__),
        "float_steps": args.float_steps,
        "qat_steps": args.qat_steps,
        "batch_size": args.batch_size,
        "patch_size": args.patch,
        "content_files": [path.name for path in content_paths],
        "content_license_boundary": "case1/assets/SOURCES.md public default set",
        "style_file": args.style.name,
        "style_source_page": STYLE_SOURCE_PAGE,
        "style_license": STYLE_LICENSE,
        "style_palette_rgb01": targets["palette"].detach().cpu().tolist(),
        "loss": (
            "style-palette supervised target + low-frequency content + "
            "fixed-feature style Gram/colour + edge + TV"
        ),
        "float_first": float_first,
        "float_last": float_last,
        "qat_first": qat_first,
        "qat_last": qat_last,
        "preview": _float_terms(preview_terms),
        "weight_delta_l2_from_seeded_initialization": weight_delta_l2,
        "preview_output_change_mae_u8": output_change_mae,
        "preview_output_saturation_fraction": output_saturation,
        "elapsed_seconds": elapsed,
        "quality_boundary": (
            "Small six-image/one-style engineering run. It proves optimization, "
            "QAT and RTL export, not competition-grade perceptual quality."
        ),
    }
    manifest = export_quantized_artifact(qat, args.artifact_dir, training_metadata)

    checkpoint = {
        "schema_version": 1,
        "architecture": "MicroStyle-24 BN-folded QAT",
        "model_state": qat.model.state_dict(),
        "activation_scales": activation_scales,
        "weight_scales": qat.serializable_weight_scales(),
        "training": training_metadata,
    }
    torch.save(checkpoint, args.artifact_dir / "checkpoint_qat.pt")

    # A small public-content vector pins all 22 integer stages without making
    # every automated test rerun training.
    regression_input = _resize_tensor(content_images[0], 32, device)
    regression_input_u8 = _image_u8(regression_input)
    integer_output, integer_layers = integer_infer_rgb(
        regression_input_u8, args.artifact_dir, collect=True
    )
    with torch.no_grad():
        qat_codes, qat_layers = qat.forward_codes(regression_input, collect=True)
        qat_output_u8 = np.clip(
            torch.round(qat_codes[0].permute(1, 2, 0) + 128.0).cpu().numpy(), 0, 255
        ).astype(np.uint8)
    layer_max_error: dict[str, int] = {}
    for name, expected in integer_layers.items():
        if name not in qat_layers:
            continue
        observed = torch.round(qat_layers[name][0]).cpu().numpy().transpose(1, 2, 0)
        layer_max_error[name] = int(
            np.max(np.abs(expected.astype(np.int16) - observed.astype(np.int16)))
        )
    integer_qat_max_error = int(
        np.max(np.abs(integer_output.astype(np.int16) - qat_output_u8.astype(np.int16)))
    )
    if integer_qat_max_error != 0 or any(layer_max_error.values()):
        raise AssertionError(
            f"exported integer/QAT mismatch: output={integer_qat_max_error}, "
            f"layers={layer_max_error}"
        )
    np.savez_compressed(
        args.artifact_dir / "integer_regression.npz",
        input_rgb_u8=regression_input_u8,
        expected_rgb_u8=integer_output,
    )

    args.output_dir.mkdir(parents=True, exist_ok=True)
    _save_rgb(args.output_dir / "preview_input.png", preview_input_u8)
    _save_rgb(
        args.output_dir / "preview_target.png", _image_u8(preview_supervised_target)
    )
    _save_rgb(args.output_dir / "preview_qat.png", preview_output_u8)
    _save_rgb(
        args.output_dir / "preview_pair.png",
        np.concatenate((preview_input_u8, preview_output_u8), axis=1),
    )
    report = {
        "artifact_dir": str(args.artifact_dir),
        "descriptor_count": manifest["descriptor_count"],
        "descriptor_bytes": manifest["descriptor_bytes"],
        "parameter_arena_bytes": manifest["parameter_arena_bytes"],
        "convolution_weights": manifest["convolution_weights"],
        "integer_qat_max_abs_error": integer_qat_max_error,
        "integer_layer_max_abs_error": layer_max_error,
        "training": training_metadata,
        "float_trace": float_trace,
        "qat_trace": qat_trace,
    }
    (args.output_dir / "training_metrics.json").write_text(
        json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )
    print(
        "C1_MICROSTYLE_QAT_TRAIN_PASS",
        f"float_steps={args.float_steps}",
        f"qat_steps={args.qat_steps}",
        f"descriptors={manifest['descriptor_count']}",
        f"arena={manifest['parameter_arena_bytes']}",
        f"weight_delta={weight_delta_l2:.6f}",
        f"integer_error={integer_qat_max_error}",
        f"elapsed={elapsed:.3f}s",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

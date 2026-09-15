"""Regression checks for the frozen MicroStyle-24 descriptor sequence."""

from __future__ import annotations

from microstyle_layout import build_layout, layer_specs


def main() -> int:
    descriptors, manifest = build_layout()
    specs = layer_specs()
    assert len(descriptors) == len(specs) == 22
    assert manifest["convolution_weights"] == 12_212
    assert manifest["macs_per_frame"] == 428_236_800
    assert manifest["descriptor_bytes"] == 22 * 64
    assert manifest["parameter_arena_bytes"] == 16_896
    assert manifest["execution_model"] == "dedicated_multirate_streaming_graph"
    assert "not a sequential DDR tensor" in manifest["descriptor_role"]
    assert specs[0].input_width == 640 and specs[0].output_width == 320
    assert specs[1].output_width == 160 and specs[1].output_channels == 24
    assert specs[-1].output_width == 640 and specs[-1].output_channels == 3
    assert sum(spec.weight_count for spec in specs) == 12_212
    for descriptor in descriptors:
        assert len(descriptor.pack()) == 64
    print(
        "C1_MICROSTYLE_LAYOUT_TEST_PASS",
        f"descriptors={len(descriptors)}",
        f"weights={manifest['convolution_weights']}",
        f"parameter_bytes={manifest['parameter_arena_bytes']}",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

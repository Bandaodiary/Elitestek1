"""Candidate export + independent integer stage checks, not trained quality/FPS."""
import json
from pathlib import Path
from contextlib import contextmanager

import numpy as np
import torch

from r2_execution_plan import FRAME, OP_OUTPUT_RGB
from r2_plan_package import compile_package
from r2_style_candidates import candidate_nodes, candidates
from r2_style_quant import fold_student, calibrate_student, QATStudent, export_student, integer_student
from r2_style_student import R2StyleStudent


@contextmanager
def artifact_area(root, name):
    # Plain inherited-ACL mkdir avoids Windows Python's mode-0700 temporary
    # directory behavior in a restricted desktop sandbox.
    directory = root/name
    directory.mkdir()
    try:
        yield directory
    finally:
        artifact = directory/'artifact'
        if artifact.exists():
            for filename in ('manifest.json', 'parameter_arena.bin'):
                path = artifact/filename
                if path.exists():
                    path.unlink()
            artifact.rmdir()
        directory.rmdir()


def main():
    torch.set_num_threads(1)
    torch.set_num_interop_threads(1)
    torch.manual_seed(20260915)
    rng = np.random.default_rng(20260915)
    images = [rng.integers(0,256,(12,16,3),dtype=np.uint8),
              np.zeros((12,16,3),dtype=np.uint8), np.full((12,16,3),255,dtype=np.uint8)]
    batches = [torch.from_numpy(x.transpose(2,0,1).copy())[None].float()/255 for x in images]
    temp_root = Path(__file__).resolve().parents[1]/'outputs'/'c36_quant_test_tmp'
    temp_root.mkdir(exist_ok=True)
    rows = []
    for name, config in candidates():
        source = R2StyleStudent(**config).eval()
        folded = fold_student(source)
        with torch.no_grad():
            original, stages_a = source(batches[0], True)
            fused, stages_b = folded(batches[0], True)
            for node in source.nodes:
                if node.spec.opcode != OP_OUTPUT_RGB:
                    torch.testing.assert_close(stages_a[node.spec.name], stages_b[node.spec.name], rtol=2e-5, atol=2e-6)
            assert (original-fused).abs().max() <= 1/255 + 1e-7
        scales = calibrate_student(folded, batches)
        qat = QATStudent(folded, scales).eval()
        with artifact_area(temp_root, name) as directory:
            artifact = Path(directory)/'artifact'
            manifest = export_student(qat, artifact, dict(trained=False, purpose='synthetic arithmetic test'))
            assert manifest['trained'] is False and manifest['quality_validated'] is False
            package = compile_package(candidate_nodes(**config), artifact=artifact)
            nodes = candidate_nodes(**config, width=16, height=12)
            arrays = {n.spec.name: qat.quantized_arrays(n.spec.name) for n in nodes if n.spec.name in qat.quant_parameters}
            for key in arrays:
                for expected, actual in zip(arrays[key], package.layers[key]):
                    np.testing.assert_array_equal(actual, expected)
            for image, batch in zip(images, batches):
                golden, stages_int = integer_student(image, nodes, package.layers, collect=True)
                with torch.no_grad():
                    output, stages_qat = qat(batch, True)
                actual = output[0].mul(255).round().byte().numpy().transpose(1,2,0)
                np.testing.assert_array_equal(actual, golden)
                for node in nodes:
                    if node.spec.opcode == OP_OUTPUT_RGB:
                        continue
                    actual_stage = stages_qat[node.spec.name][0].numpy().transpose(1,2,0)
                    np.testing.assert_array_equal(actual_stage, stages_int[node.spec.name])
            rows.append(dict(candidate=name, frames=len(images), stages=len(nodes),
                             parameter_arena_bytes=manifest['parameter_arena_bytes'], plan_bytes=len(package.image)))
        if name == 'r2_e24_preproject':
            qat.train()
            loss = (qat(batches[0])-batches[0]).square().mean()
            loss.backward()
            grads = [p.grad for p in qat.model.parameters()]
            assert all(g is not None and torch.isfinite(g).all() for g in grads)
            assert sum(int(g.abs().sum()>0) for g in grads) == len(grads)
            bad = dict(scales)
            bad['res0.add_relu'] *= 2
            try:
                QATStudent(folded, bad)
            except ValueError as exc:
                assert 'equal activation scales' in str(exc)
            else:
                raise AssertionError('unmatched residual scales accepted')
    # Only our now-empty test-owned folder is removed; temporary artifacts have
    # already been removed by their scoped artifact-area context managers.
    temp_root.rmdir()
    print('C36_STYLE_QUANT_PASS '+json.dumps(dict(candidates=len(rows), bitexact_frames=sum(r['frames'] for r in rows),
        all_internal_stages_checked=True, BN_folding_checked=True, mismatched_residual_scales_rejected=True,
        gradient_connected=True, trained_model_tested=False, RTL_simulated=False, rows=rows)))


if __name__ == '__main__':
    main()

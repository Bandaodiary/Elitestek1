"""Boardless C37 integration with frozen trained models and real AXI/video RTL.

Small regressions only. Native full-frame xsim belongs in the separate detached
pipeline; no waves or generated simulator projects are retained here.
"""
import argparse
import json
from pathlib import Path
import tempfile
import torch
from c37_sources import ROOT, sources
from run_c37_leaf_probe import budget, compile_test, run_test
from r2_trained_style_vectors import bound_candidate, build_vectors
from r2_fused_camera_vectors import camera_geometry

TOP = 'tb_c1_r2_fused_rgb2_host_system'
PREFIX = 'C1_R2_FUSED_RGB2_HOST_SYSTEM_'
MODELS = {
    'starry': 'c36_qat_b_starry_equalized_20260915a',
    'mosaic': 'c36_qat_b_mosaic_equalized_20260915a',
    'stable': 'c36_qat_b_mosaic_stable_20260915a',
}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--model', choices=tuple(MODELS), default='stable')
    parser.add_argument('--shapes', default='8x8,32x32')
    parser.add_argument('--stalls', default='0,1')
    parser.add_argument('--negative', action='store_true')
    args = parser.parse_args()
    shapes = [tuple(map(int, item.split('x'))) for item in args.shapes.split(',')]
    if any(len(s)!=2 or any(n<4 or n>64 or n%4 for n in s) for s in shapes):
        parser.error('small regression only: dimensions must be multiples of 4 in [4,64]')
    stalls = tuple(map(int, args.stalls.split(',')))
    if not stalls or not set(stalls) <= {0,1}:
        parser.error('stalls must be 0 and/or 1')
    budget()
    torch.set_num_threads(2)
    model = ROOT / 'outputs' / MODELS[args.model]
    package, config, provenance = bound_candidate(model)
    provenance.update(production_RTL_changed=True, candidate='C37',
                      source_replacement_contract='golden/c37_sources.py')
    count = 0
    with tempfile.TemporaryDirectory(prefix='c37_host_', dir=ROOT/'sim') as temporary:
        work = Path(temporary)
        for w,h in shapes:
            folder = work / f'{w}x{h}'
            meta = build_vectors(folder, w, h, package, config, provenance)
            production = sources(model)
            # Rebuilt ROM must equal the exact saved model ROM in the closure.
            for actual, saved in ((folder/'package/execution_plan.sv', model/'plan_fused/execution_plan.sv'),
                                  (folder/'fusion_plan.sv', model/'plan_fused/row_fusion_plan.sv')):
                if actual.read_text()!=saved.read_text():
                    raise ValueError('private and deployed ROM differ')
            sw,sh,rx,ry,rw,rh = camera_geometry(w,h)
            for stall in stalls:
                for negative in ((1,2) if args.negative else (0,)):
                    options = dict(WIDTH=w, HEIGHT=h, STALLS=stall, AW_WAIT_W=2,
                        FRAME_DIVISOR=2, CAMERA_SW=sw, CAMERA_SH=sh, CAMERA_RX=rx,
                        CAMERA_RY=ry, CAMERA_RW=rw, CAMERA_RH=rh, NN_TARGET=2,
                        NEGATIVE_CONTROL=negative, STAGE_COUNT=meta['stage_count'],
                        RGB_STAGE=meta['rgb_stage'], FUSED_DW_STAGE=meta['dw_stage'],
                        FUSED_PW_STAGE=meta['pw_stage'])
                    tb = [ROOT / 'sim' / name for name in (
                        'c1_r2_axi_memory_bfm.sv','c1_r2_axi_traffic_agent.sv',TOP+'.sv')]
                    exe = compile_test(work, TOP, production+tb,
                                       [f'-P{TOP}.{k}={v}' for k,v in options.items()])
                    plusargs = [f'+DIR={folder.as_posix()}', f'+P={meta["parameter_words"]}',
                        f'+I={meta["input_words"]}', f'+E={meta["expected_words"]}', f'+DW={meta["dw_packets"]}']
                    plusargs += [f'+{tag}{i}={source[key]}' for i,source in enumerate(meta['sources'])
                        for tag,key in (('SW','width'),('SH','height'),('XS','xs'),('YS','ys'),('XP','xp'),('YP','yp'))]
                    print('C37_HOST_CASE ' + json.dumps(dict(model=args.model, width=w,height=h,
                          stalls=stall,negative=negative,production_sources=len(production),
                          actual_trained_parameters=True,actual_AXI_video=True)), flush=True)
                    reason = {0: None,1:'CNN golden mismatch stage=0',2:'display pair not actually produced'}[negative]
                    run_test(work, exe, plusargs, PREFIX+'PASS ', reason, timeout=900)
                    count += 1
    print(f'C37_HOST_CLEAN model={args.model} configurations={count} '
          'temporary_vectors_and_simulator_removed=1 native_fps_claim=0', flush=True)


if __name__ == '__main__':
    main()

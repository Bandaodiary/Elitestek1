"""C35 real shared-MAC DW/PW and retained-operator regressions, detached only."""
import argparse
import json
from pathlib import Path
import re
import subprocess
import tempfile

from check_r2_row_shadow_engine_source import ROOT,audited_sources
from r2_row_shadow_engine_vectors import vectors

TOP='tb_c1_r2_cnn_row_shadow_engine'
FALLBACK='tb_c1_r2_cnn_row_shadow_fallback'
SHAPES=((2,2),(6,3),(16,3),(320,2))


def preflight():
    sources=audited_sources()
    for top in (TOP,FALLBACK):assert (ROOT/f'sim/{top}.sv').is_file()
    old=(ROOT/'sim/tb_c1_r2_cnn_overlay_engine.sv').read_text(encoding='utf-8-sig')
    expected='// C35 retained all-operator regression, only top/instance and tied-off new ports differ.\n'+old
    expected=expected.replace('module tb_c1_r2_cnn_overlay_engine;',f'module {FALLBACK};')
    expected=expected.replace('    c1_r2_cnn_overlay_engine dut(.*);',
        '    c1_r2_cnn_row_shadow_engine dut(\n'
        '        .partition_en(1\'b0),.partition_base(9\'d0),.partition_end(10\'d0),\n'
        '        .start_shadow_capture(1\'b0),.start_shadow_read(1\'b0),\n'
        '        .shadow_available(),.shadow_error(),.op_done(),.*);')
    assert (ROOT/f'sim/{FALLBACK}.sv').read_text(encoding='utf-8-sig')==expected
    print('C35_SHADOW_ENGINE_PREFLIGHT '+json.dumps(dict(production_sources=len(sources),
        normal_configurations=8,reset_configurations=2,fallback_configurations=2,
        real_negative_controls=3,retained_fallback_assertions_unchanged=True,
        RTL_compiled=False,RTL_simulated=False,native_fps_claim=False),separators=(',',':')),flush=True)
    return sources


def require_pw_run(run):
    from run_r2_pw_shadow_probe import validate
    if not re.fullmatch(r'[A-Za-z0-9_-]+',run):raise ValueError('invalid PW predecessor RunId')
    folder=ROOT/'logs/r2_pw_shadow_runs'/run
    status=json.loads((folder/'status.json').read_text(encoding='utf-8-sig'))
    private=(ROOT/'sim'/f'c1_r2_pw_shadow_{run}').resolve()
    if (status.get('run_id')!=run or status.get('state')!='complete' or status.get('exit_code')!=0 or
        status.get('worker_in_windows_job') is not False or status.get('simulator_directory_present') is not False or
        Path(status['run_directory']).resolve()!=private or private.exists()):raise ValueError('PW run not complete/clean/isolated')
    budget=status.get('workload_budget') or {}
    if budget.get('logical_processors') not in (1,2) or budget.get('priority')!='BelowNormal':raise ValueError('wrong PW budget')
    if (folder/'result.log').stat().st_size>65536:raise ValueError('oversized PW component log')
    if (folder/'result.stderr.log').read_text(encoding='utf-8-sig').strip():raise ValueError('PW stderr not empty')
    text=(folder/'result.log').read_text(encoding='utf-8-sig');validate(text)
    if text.splitlines().count('C35_PW_SHADOW_CLEAN temporary_simulator_removed=1')!=1:raise ValueError('PW cleanup record missing')
    print('C35_PW_SHADOW_EVIDENCE_PASS '+json.dumps(dict(run=run,actual_RAM_to_PW_feeder=True,
        real_DW_PW_arithmetic=False,full_graph=False,native_fps_claim=False,
        process_liveness_not_inferred=True),separators=(',',':')),flush=True)


def parse_fields(line):
    pairs=re.findall(r'(\w+)=(\d+)',line);fields={key:int(value) for key,value in pairs}
    if len(fields)!=len(pairs):raise ValueError('duplicate result field')
    return fields


def main():
    ap=argparse.ArgumentParser();ap.add_argument('--preflight-only',action='store_true')
    ap.add_argument('--temporary-parent',type=Path);ap.add_argument('--pw-run');args=ap.parse_args();sources=preflight()
    if args.preflight_only:return
    if not args.pw_run or args.temporary_parent is None:raise ValueError('requires predecessor and detached private parent')
    require_pw_run(args.pw_run)
    parent=args.temporary_parent.resolve(strict=True);sim=(ROOT/'sim').resolve(strict=True)
    if parent==sim or sim not in parent.parents or not parent.name.startswith('c1_r2_shadow_engine_'):
        raise ValueError('invalid private parent')
    totals=dict(configurations=0,operations=0,packets=0,shadow_words=0,fallback_configurations=0,negative_controls=0)
    with tempfile.TemporaryDirectory(prefix='arithmetic_',dir=parent) as td:
        work=Path(td);executables={}

        def compile_test(top,stalls,negative=0,reset_phase=0):
            key=top,stalls,negative,reset_phase
            if key in executables:return executables[key]
            exe=work/f'{top}_{stalls}_{negative}_{reset_phase}.vvp'
            params=[f'-P{top}.STALLS={stalls}']
            if top==TOP:params.extend((f'-P{top}.NEGATIVE={negative}',f'-P{top}.RESET_PHASE={reset_phase}'))
            command=['D:/iverilog/bin/iverilog.exe','-g2012','-s',top,*params,'-o',str(exe),
                     *map(str,sources),str(ROOT/f'sim/{top}.sv')]
            result=subprocess.run(command,cwd=work,capture_output=True,text=True,errors='replace')
            if result.returncode:
                diagnostic=result.stdout+result.stderr
                if len(diagnostic)>4000:diagnostic=diagnostic[:1800]+'\n[diagnostic middle omitted]\n'+diagnostic[-1800:]
                raise RuntimeError('compile failed '+diagnostic)
            executables[key]=exe;return exe

        def run_case(width,height,stalls,reset_phase=0,negative=0):
            folder=work/f'input_{width}_{height}_{stalls}_{reset_phase}_{negative}';folder.mkdir()
            meta=vectors(folder,width,height)
            exe=compile_test(TOP,stalls,negative,reset_phase)
            arguments=[f'+INPUTS={folder.as_posix()}/commands.mem',f'+OUTPUTS={folder.as_posix()}/expected.mem',
                       f'+SHADOW={folder.as_posix()}/shadow.mem',f'+N={meta["commands"]}',f'+M={meta["packets"]}',
                       f'+S={meta["shadow_words"]}',f'+J={meta["operations"]}',f'+BULK={meta["bulk_writes"]}',
                       f'+PARAMS={meta["parameter_writes"]}',f'+BAD_BIAS={meta["bad_bias_channel"]}']
            result=subprocess.run(['D:/iverilog/bin/vvp.exe',str(exe),*arguments],cwd=work,
                                  capture_output=True,text=True,errors='replace')
            if negative:
                reasons={1:('shadow memory golden mismatch',),2:('shadow engine DW/PW numeric mismatch',),
                         3:('partition window linear reader before spatial drain','partition RAM two readers')}[negative]
                if not result.returncode or not any(reason in result.stdout for reason in reasons) or 'C35_SHADOW_ENGINE_PASS ' in result.stdout:
                    raise RuntimeError('wrong actual arithmetic negative '+(result.stdout+result.stderr)[-4000:])
                print(f'C35_SHADOW_ENGINE_NEGATIVE_PASS case={negative} actual_DUT_corruption=1',flush=True)
                totals['negative_controls']+=1;return
            lines=[line for line in result.stdout.splitlines() if line.startswith('C35_SHADOW_ENGINE_PASS ')]
            if result.returncode or len(lines)!=1 or 'FATAL' in result.stdout:
                raise RuntimeError((result.stdout+result.stderr)[-4000:])
            fields=parse_fields(lines[0])
            exact={key:meta[key] for key in ('operations','DW_rows','PW_rows','packets','shadow_words','bulk_writes','parameter_writes')}
            exact.update(stalls=stalls,reset_phase=reset_phase,mac_beats=meta['packets'],resets=int(reset_phase!=0),
                         real_DW_PW_arithmetic=1,checker_only_intermediates=1,actual_AXI=0,full_graph=0)
            if any(fields.get(k)!=v for k,v in exact.items()):raise RuntimeError('arithmetic coverage mismatch '+lines[0])
            if stalls and fields.get('held_cycles',0)<8:raise RuntimeError('no actual arithmetic backpressure')
            if reset_phase and fields.get('discarded_packets',0)<3:raise RuntimeError('reset not in actual arithmetic')
            if width>=6 and fields.get('overlap_cycles',0)==0:raise RuntimeError('no actual DW-window/shadow-write overlap')
            print('C35_SHADOW_ENGINE_CASE '+json.dumps(dict(width=meta['width'],height=meta['height'],**fields),separators=(',',':')),flush=True)
            totals['configurations']+=1
            for key in ('operations','packets','shadow_words'):totals[key]+=meta[key]

        for width,height in SHAPES:
            for stalls in (0,1):run_case(width,height,stalls)
        for phase in (1,2):run_case(6,3,1,reset_phase=phase)
        for negative in (1,2,3):run_case(6,3,1,negative=negative)

        # Existing mathematical stimulus and ALL its RTL assertions remain.
        from run_r2_overlay_operator_probe import vectors as fallback_vectors
        fallback_folder=work/'fallback';fallback_folder.mkdir();meta=fallback_vectors(fallback_folder)
        print('C35_SHADOW_ENGINE_FALLBACK_VECTORS '+json.dumps(meta,separators=(',',':')),flush=True)
        for stalls in (0,1):
            exe=compile_test(FALLBACK,stalls)
            result=subprocess.run(['D:/iverilog/bin/vvp.exe',str(exe),f'+INPUTS={fallback_folder.as_posix()}/bulk.mem',
                f'+OUTPUTS={fallback_folder.as_posix()}/reference/output.mem',f'+N={meta["commands"]}',
                f'+M={meta["vectors"]}',f'+J={meta["jobs"]}'],cwd=work,capture_output=True,text=True,errors='replace')
            rows=[line for line in result.stdout.splitlines() if line.startswith('C1_R2_OVERLAY_OPERATOR_PASS ')]
            if result.returncode or len(rows)!=1 or 'FATAL' in result.stdout:
                raise RuntimeError('fallback failed '+(result.stdout+result.stderr)[-4000:])
            fields=parse_fields(rows[0])
            if any(fields.get(k)!=v for k,v in dict(stalls=stalls,jobs=meta['jobs'],vectors=meta['vectors'],
                bulk_writes=meta['bulk'],reset_modes=6,packed_weights=1,lanes=6).items()):raise RuntimeError('fallback coverage mismatch')
            print('C35_SHADOW_ENGINE_FALLBACK_PASS '+json.dumps(fields,separators=(',',':')),flush=True)
            totals['fallback_configurations']+=1
    assert totals==dict(configurations=10,operations=104,packets=25252,shadow_words=23296,fallback_configurations=2,negative_controls=3)
    print('C35_SHADOW_ENGINE_CLEAN temporary_vectors_and_simulator_removed=1',flush=True)
    print('C35_SHADOW_ENGINE_SUMMARY '+json.dumps(dict(**totals,full_graph=False,actual_AXI=False,native_fps_claim=False,
        physical_RAM_measured=False),separators=(',',':')),flush=True)


if __name__=='__main__':main()

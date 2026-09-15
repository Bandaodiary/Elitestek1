"""C35 isolated real RAM/packet regression. Run EDA only in detached worker.

--preflight-only reads source files and reports the test matrix; it does NOT
compile or simulate RTL. Hardware runs require a caller-owned private folder.
"""
import argparse
import json
from pathlib import Path
import re
import subprocess
import tempfile

ROOT=Path(__file__).resolve().parents[1]
TOP='tb_c1_r2_dw16_row_shadow'
SOURCES=['rtl/common/c1_ram_sdp_read_first.sv','rtl/r2/c1_r2_partitioned_feature_ram.sv',
         'rtl/r2/c1_r2_dw16_row_shadow_writer.sv',f'sim/{TOP}.sv']
REASONS={1:'two readers',2:'two writers',3:'same-view read/refill',4:'same-view read/refill',
         5:'invalid bounds',6:'linear read outside shadow',7:'spatial read outside source',
         8:'linear write outside shadow',9:'spatial write outside source',10:'changed active lease',
         11:'linear view needs refill',12:'fallback ownership collision'}


def preflight():
    for filename in SOURCES:
        path=ROOT/filename
        assert path.is_file() and 0<path.stat().st_size<50000,filename
    ram=(ROOT/SOURCES[1]).read_text(encoding='utf-8-sig')
    sink=(ROOT/SOURCES[2]).read_text(encoding='utf-8-sig')
    tb=(ROOT/SOURCES[3]).read_text(encoding='utf-8-sig')
    assert 'id<8' in ram and '.DATA_WIDTH(32),.DEPTH(512),.ADDR_WIDTH(9)' in ram
    assert 'spatial_wr_addr[0]==HALF' in ram and 'spatial_wr_addr[9:1]' in ram
    assert 'wire [15:0] expected_index={pixel_q,2\'b00,group_q,phase_q};' in sink
    assert 'if(take && packet_good && !error)' in sink
    assert 'row_valid<=!error && packet_good' in sink
    assert all(f'{case}:' in tb for case in REASONS)
    assert '$dump' not in tb
    # Independent calculation of the planned positive coverage, not DUT
    # evidence: normal rows plus error drains and cancelled partial rows.
    good_widths=[4,4,12,12,32,32,640,640]+[12]*9
    planned_packets=sum(w*3 for w in good_widths)+(36+36+5+37)+(1+2+3+35)
    print('C35_ROW_SHADOW_PREFLIGHT '+json.dumps(dict(sources=len(SOURCES),
        positive_configurations=1,assertion_negatives=len(REASONS),planned_complete_rows=len(good_widths),
        planned_accepted_packets=planned_packets,RTL_compiled=False,RTL_simulated=False,
        physical_RAM_measured=False,native_fps_claim=False),separators=(',',':')),flush=True)


def validate_result(stdout):
    records=[x for x in stdout.splitlines() if x.startswith('C35_ROW_SHADOW_PASS ')]
    if len(records)!=1 or 'FATAL' in stdout:raise RuntimeError('missing/unexpected positive evidence')
    fields=dict(re.findall(r'(\w+)=(\d+)',records[0]));fields={k:int(v) for k,v in fields.items()}
    exact=dict(rows=17,packets=4607,protocol_cases=8,aborts=3,resets=1,byte_capacity=16384,
               read_latency=1,invalid_padding_poisoned=1)
    if any(fields.get(k)!=v for k,v in exact.items()):raise RuntimeError('wrong positive coverage '+records[0])
    if any(fields.get(k,0)<v for k,v in dict(packet_word_checks=6000,cross_cycles=4000,
        linear_reads=1000,spatial_reads=6000,stall_cycles=6000).items()):raise RuntimeError('insufficient coverage '+records[0])
    return records[0]


def main():
    ap=argparse.ArgumentParser();ap.add_argument('--preflight-only',action='store_true')
    ap.add_argument('--temporary-parent',type=Path);args=ap.parse_args()
    preflight()
    if args.preflight_only:return
    if args.temporary_parent is None:raise ValueError('EDA requires detached worker private parent')
    parent=args.temporary_parent.resolve(strict=True);sim=(ROOT/'sim').resolve(strict=True)
    if parent==sim or sim not in parent.parents or not parent.name.startswith('c1_r2_row_shadow_'):
        raise ValueError('invalid C35 private parent')
    with tempfile.TemporaryDirectory(prefix='component_',dir=parent) as td:
        exe=Path(td)/'shadow.vvp'
        for case in range(13):
            command=['D:/iverilog/bin/iverilog.exe','-g2012','-s',TOP,f'-P{TOP}.NEGATIVE={case}',
                     '-o',str(exe),*[str(ROOT/s) for s in SOURCES]]
            # Outer worker pins the actual Python handle and owns the full
            # process tree timeout. Avoid orphaning ivl by timing out only
            # its compiler frontend inside this process.
            compiled=subprocess.run(command,cwd=td,capture_output=True,text=True,errors='replace')
            if compiled.returncode:
                raise RuntimeError('compile failed '+(compiled.stdout+compiled.stderr)[-3500:])
            result=subprocess.run(['D:/iverilog/bin/vvp.exe',str(exe)],cwd=td,
                                  capture_output=True,text=True,errors='replace')
            if case==0:
                if result.returncode:raise RuntimeError((result.stdout+result.stderr)[-3500:])
                print(validate_result(result.stdout),flush=True)
            else:
                reason='partition RAM '+REASONS[case]
                if not result.returncode or reason not in result.stdout or 'C35_ROW_SHADOW_PASS ' in result.stdout:
                    raise RuntimeError('wrong negative result '+(result.stdout+result.stderr)[-3500:])
                print(f'C35_ROW_SHADOW_NEGATIVE_PASS case={case} reason={REASONS[case]}',flush=True)
    print('C35_ROW_SHADOW_CLEAN temporary_simulator_removed=1',flush=True)
    print('C35_ROW_SHADOW_SUMMARY positive_configurations=1 assertion_negatives=12 actual_CNN=0 actual_AXI=0 native_fps_claim=0',flush=True)


if __name__=='__main__':main()

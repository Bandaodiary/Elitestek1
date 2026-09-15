"""C35 PW shadow feeder: actual packet-written RAM and retained feeder pair."""
import argparse
import json
from pathlib import Path
import re
import subprocess
import tempfile

ROOT=Path(__file__).resolve().parents[1]
TOP='tb_c1_r2_pw_shadow_feeder'
SOURCES=['rtl/common/c1_ram_sdp_read_first.sv','rtl/r2/c1_r2_partitioned_feature_ram.sv',
         'rtl/r2/c1_r2_dw16_row_shadow_writer.sv','rtl/r2/c1_r2_pw_overlay_feeder.sv',
         'rtl/r2/c1_r2_pw_shadow_feeder.sv',f'sim/{TOP}.sv']


def preflight():
    for file in SOURCES:
        path=ROOT/file
        assert path.is_file() and 0<path.stat().st_size<50000,file
    candidate=(ROOT/SOURCES[4]).read_text(encoding='utf-8-sig')
    retained=(ROOT/SOURCES[3]).read_text(encoding='utf-8-sig')
    # Remove only the explicit shadow additions, then compare the ENTIRE
    # retained implementation, not just a handful of selected source lines.
    candidate=candidate.removeprefix('// C35 independent shadow-read candidate. Retained feeder is unchanged.\n'
        '// start_shadow=0 preserves its address/operand schedule, including tails.\n'
        '// start_shadow=1 selects an already-published DW16 row; no feature refill.\n')
    replacements=[
        ('module c1_r2_pw_shadow_feeder (','module c1_r2_pw_overlay_feeder ('),
        ('    input wire start_shadow,\n    input wire [8:0] start_shadow_base,\n',''),
        ('    wire [14:0] shadow_end={6\'d0,start_shadow_base}+{2\'d0,start_count[13:1]};\n'
         '    wire legal_shadow=!start_linear && start_channels==16 && start_outputs==8 &&\n'
         '        start_count>=4 && start_count<=640 && start_count[1:0]==0 &&\n'
         '        {5\'d0,start_shadow_base}>=(start_count>>2) && shadow_end<=512;\n'
         '    assign start_ready=!rst && !busy && start_count!=0 && (!start_shadow || legal_shadow) &&\n'
         '        (start_linear ? start_count<=8192 : legal_channels && legal_size);',
         '    assign start_ready=!rst && !busy && start_count!=0 && (start_linear ? start_count<=8192 : legal_channels && legal_size);'),
        ('    logic linear_q,tail8_q,shadow_q;\n    logic [8:0] shadow_base_q;\n    logic [9:0] shadow_width_q;',
         '    logic linear_q,tail8_q;'),
        ('    wire [9:0] even_pixel_raw=issue_pixel+issue_pixel[0];\n'
         '    // Cout8\'s last request may read an unused even bank beyond the row.\n'
         '    // Clamp only in shadow mode; valid lanes retain their original address.\n'
         '    wire [9:0] even_pixel=shadow_q && even_pixel_raw>=shadow_width_q ? shadow_width_q-1\'b1 : even_pixel_raw;',
         '    wire [9:0] even_pixel=issue_pixel+issue_pixel[0];'),
        ('    wire [8:0] odd_address=shadow_base_q+feature_address(odd_pixel,chunks_q,issue_k);\n'
         '    wire [8:0] even_address=shadow_base_q+feature_address(even_pixel,chunks_q,issue_k);\n'
         '    assign feature_rd_addr={odd_address,even_address};',
         '    assign feature_rd_addr={feature_address(odd_pixel,chunks_q,issue_k),feature_address(even_pixel,chunks_q,issue_k)};'),
        ('            shadow_q<=0;shadow_base_q<=0;shadow_width_q<=0;\n',''),
        ('                shadow_q<=start_shadow;shadow_base_q<=start_shadow ? start_shadow_base : 9\'d0;\n'
         '                shadow_width_q<=start_count[9:0];\n','')]
    for a,b in replacements:
        assert candidate.count(a)==1,'missing/nonunique declared feeder change'
        candidate=candidate.replace(a,b)
    assert candidate==retained,'undeclared retained-feeder modification'
    # Planned coverage calculation is independent of the RTL checker output.
    rows=[(4,16,8),(12,16,8),(32,16,8),(640,16,8),(12,16,8),
          (12,16,8),(12,24,24),(12,48,48),(32,16,48),(340,48,8)]
    requests=sum(((w*co+5)//6)*((ci+15)//16) for w,ci,co in rows)+3
    vectors=sum(w*co*((ci+15)//16) for w,ci,co in rows)+18
    assert (requests,vectors)==(2956,17714)
    print('C35_PW_SHADOW_PREFLIGHT '+json.dumps(dict(sources=len(SOURCES),declared_source_changes=len(replacements),
        planned_complete_rows=10,planned_cancelled_rows=1,planned_requests=requests,planned_active_vectors=vectors,
        RTL_compiled=False,RTL_simulated=False,physical_RAM_measured=False,native_fps_claim=False),separators=(',',':')),flush=True)


def validate(stdout):
    lines=[line for line in stdout.splitlines() if line.startswith('C35_PW_SHADOW_FEEDER_PASS ')]
    if len(lines)!=1 or 'FATAL' in stdout:raise RuntimeError('missing or invalid PW feeder result')
    pairs=re.findall(r'(\w+)=(\d+)',lines[0]);fields={k:int(v) for k,v in pairs}
    if len(fields)!=len(pairs):raise RuntimeError('duplicate coverage field')
    exact=dict(complete_rows=10,cancelled_rows=1,rejected=7,requests=2956,active_vectors=17714,clamp_reads=7,
               retained_schedule_checked=1,actual_DW_packet_RAM_source=1)
    if any(fields.get(k)!=v for k,v in exact.items()) or fields.get('stall_checks',0)<100:
        raise RuntimeError('PW feeder coverage mismatch '+lines[0])
    return lines[0]


def main():
    ap=argparse.ArgumentParser();ap.add_argument('--preflight-only',action='store_true')
    ap.add_argument('--temporary-parent',type=Path);ap.add_argument('--row-shadow-run');args=ap.parse_args();preflight()
    if args.preflight_only:return
    if not args.row_shadow_run:raise ValueError('requires actual predecessor component run')
    from check_r2_row_shadow_evidence import gate_run
    gate_run(args.row_shadow_run)
    if args.temporary_parent is None:raise ValueError('requires detached private parent')
    parent=args.temporary_parent.resolve(strict=True);sim=(ROOT/'sim').resolve(strict=True)
    if parent==sim or sim not in parent.parents or not parent.name.startswith('c1_r2_pw_shadow_'):
        raise ValueError('invalid private parent')
    with tempfile.TemporaryDirectory(prefix='feeder_',dir=parent) as td:
        exe=Path(td)/'feeder.vvp'
        command=['D:/iverilog/bin/iverilog.exe','-g2012','-s',TOP,'-o',str(exe),*[str(ROOT/s) for s in SOURCES]]
        compiled=subprocess.run(command,cwd=td,capture_output=True,text=True,errors='replace')
        if compiled.returncode:
            diagnostic=compiled.stdout+compiled.stderr
            if len(diagnostic)>4000:diagnostic=diagnostic[:1800]+'\n[diagnostic middle omitted]\n'+diagnostic[-1800:]
            raise RuntimeError('compile failed '+diagnostic)
        result=subprocess.run(['D:/iverilog/bin/vvp.exe',str(exe)],cwd=td,capture_output=True,text=True,errors='replace')
        if result.returncode:raise RuntimeError((result.stdout+result.stderr)[-3500:])
        print(validate(result.stdout),flush=True)
    print('C35_PW_SHADOW_CLEAN temporary_simulator_removed=1',flush=True)


if __name__=='__main__':main()

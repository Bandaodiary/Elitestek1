"""Legacy full-capture entry point using the promoted production sampler.

The two-versus-four-row diagnostic predates production promotion and cannot
be rerun against this source tree. Prefer run_c40_production_regression.py.
"""
import argparse
import json
import subprocess
import tempfile
from pathlib import Path
from run_r2_demo_rgb2_capture_probe import ROOT, SOURCES, EXTRA, vectors
from run_c40_iverilog_pipeline import process_identity, write_json
from run_c37_leaf_probe import budget
from c39_seam_admission import check
from c40_four_row_candidate import render


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--log-dir', type=Path, required=True)
    parser.add_argument('--full-frames', action='store_true')
    args = parser.parse_args()
    if not args.full_frames:
        parser.error('two-row comparison is historical; use --full-frames or the production xsim regression')
    log = args.log_dir.resolve()
    if not log.is_relative_to(ROOT/'logs/c40_100mhz_runs') or not log.is_dir():
        raise ValueError('private log directory required')
    budget(); check()
    top = 'tb_c1_r2_demo_rgb2_capture'
    original = (ROOT/f'sim/{top}.sv').read_text(encoding='utf-8-sig')
    monitor = '''
    integer d_accept=0,d_block=0,d_empty=0,d_requests=0,d_responses=0;
    integer d_rowwait=0,d_outputs=0,d_lastrow=-1;
    always @(posedge clk) if (!rst && cap_busy) begin
        if(s_valid && s_ready)d_accept=d_accept+1;
        if(s_valid && !s_ready)d_block=d_block+1;
        if(!s_valid)d_empty=d_empty+1;
        if(!capture.u_resize.u_line_sampler.row_plan_valid &&
           capture.u_resize.u_line_sampler.expected_src_x==0)d_rowwait=d_rowwait+1;
        if(capture.u_resize.sample_req_valid && capture.u_resize.sample_req_ready)d_requests=d_requests+1;
        if(capture.u_resize.sample_rsp_valid && capture.u_resize.sample_rsp_ready)d_responses=d_responses+1;
        if(capture.u_resize.out_valid && capture.u_resize.out_ready)d_outputs=d_outputs+1;
        if(s_valid && s_ready && s_eol)begin
            $display("C40_CAPTURE_ROW mhz=%0.3f y=%0d cycle=%0d accepted=%0d blocked=%0d empty=%0d rowwait=%0d req=%0d rsp=%0d output=%0d fifo_peak=%0d",500.0/CORE_HALF,s_y,cycles,d_accept,d_block,d_empty,d_rowwait,d_requests,d_responses,d_outputs,cam_peak);
            d_lastrow=s_y;
            if(s_y==31)begin
                $display("C40_CAPTURE_DIAGNOSTIC_STOP reason=32_rows overflow=0");$finish;
            end
        end
        if(ingress.source_bad)begin
            $display("C40_CAPTURE_DIAGNOSTIC_STOP reason=source_error code=%0d row=%0d x=%0d accepted=%0d blocked=%0d empty=%0d rowwait=%0d req=%0d rsp=%0d output=%0d fifo_peak=%0d",ingress.source_code,s_y,s_x,d_accept,d_block,d_empty,d_rowwait,d_requests,d_responses,d_outputs,cam_peak);
            $finish;
        end
    end
'''
    if args.full_frames:
        monitor=monitor.replace('if(s_valid && s_ready && s_eol)begin',
                                'if(s_valid && s_ready && s_eol && (s_y%128==0 || s_y==RH-1))begin')
        monitor=monitor.replace('if(s_y==31)begin','if(1\'b0)begin')
        monitor=monitor.replace('if(ingress.source_bad)begin','if(1\'b0)begin')
    fixture = original.replace('    always @(posedge cam_clk)begin', monitor+'\n    always @(posedge cam_clk)begin', 1)
    fixture=fixture.replace('$fatal(1,"camera Resize RGBX memory golden mismatch address=%h",service_write_address);',
        '$fatal(1,"camera Resize RGBX memory golden mismatch address=%h actual=%h expected=%h",service_write_address,m_axi_wdata,expected[service_write_address>>4]);')
    fixture=fixture.replace('if(capture.u_resize.sample_rsp_valid && capture.u_resize.sample_rsp_ready)d_responses=d_responses+1;',
        '''if(capture.u_resize.sample_rsp_valid && capture.u_resize.sample_rsp_ready)begin
            d_responses=d_responses+1;
            if(d_responses<=4)$display("C40_TAPS n=%0d a=%h b=%h c=%h d=%h",d_responses,
                capture.u_resize.sample_rsp_rgb_y0x0,capture.u_resize.sample_rsp_rgb_y0x1,
                capture.u_resize.sample_rsp_rgb_y1x0,capture.u_resize.sample_rsp_rgb_y1x1);
        end''')
    swaps = {'rtl/video/c1_r1_resize_system.sv':'rtl/r2/c1_r2_resize_overlap_system.sv',
             'rtl/r2/c1_r2_resize_pipeline.sv':'rtl/r2/c1_r2_resize_overlap_pipeline.sv',
             'rtl/r2/c1_r2_resize_capture_rgbx32.sv':'rtl/r2/c1_r2_resize_overlap_capture.sv'}
    with tempfile.TemporaryDirectory(prefix='c40_capture_', dir=ROOT/'sim') as td:
        work = Path(td)
        plus = vectors(work,1920,1080,240,0,1440,1080,640,480)
        tb = work/(top+'.sv'); tb.write_text(fixture,encoding='utf-8')
        (log/'testbench.sv').write_text(fixture,encoding='utf-8')
        candidate=work/'c40_four_row_sampler.sv'
        candidate.write_text(render(),encoding='utf-8')
        (log/'candidate.sv').write_text(render(),encoding='utf-8')
        cases=(('100_four',100,5.0,True),) if args.full_frames else (('100',100,5.0,False),('150',150,3.333,False),('100_four',100,5.0,True))
        for label,mhz,half,four in cases:
            opts=dict(SW=1920,SH=1080,RX=240,RY=0,RW=1440,RH=1080,OW=640,OH=480,
                      FD=512,FAULTS=0,STALLS=0,CORE_HALF=half,CAM_HALF=7.143,HBLANK=106,VBLANK=42)
            exe=work/'capture.vvp'
            commands=[['D:/iverilog/bin/iverilog.exe','-g2012','-DC30_RESIZE_OVERLAP','-s',top,
                *[f'-P{top}.{k}={v}' for k,v in opts.items()],'-o',str(exe),
                *[str(ROOT/swaps.get(s,s)) for s in SOURCES+EXTRA+['sim/c1_r2_axi_memory_bfm.sv']],str(tb)],
                ['D:/iverilog/bin/vvp.exe',str(exe),f'+DIR={work.as_posix()}',*[f'+{k}={v}' for k,v in plus.items()]]]
            write_json(log/f'{label}.commands.json',dict(parameters=opts,commands=commands,four_rows=four))
            for step,command in zip(('compile','simulate'),commands):
                with (log/f'{label}.{step}.stdout.log').open('w') as out, (log/f'{label}.{step}.stderr.log').open('w') as err:
                    child=subprocess.Popen(command,cwd=work,stdout=out,stderr=err,creationflags=subprocess.CREATE_NO_WINDOW)
                    identity=process_identity(child)
                    write_json(log/f'{label}.{step}.process.json',identity)
                    code=child.wait()
                    write_json(log/f'{label}.{step}.exit.json',dict(exit_code=code,process=identity))
                if code:raise RuntimeError(f'{mhz} {step} failed; inspect small log')
            result=(log/f'{label}.simulate.stdout.log').read_text()
            if args.full_frames:
                if result.count('C1_R2_DEMO_RGB2_CAPTURE_PASS ')!=1 or 'results=2 good=2 bad=0' not in result:
                    raise AssertionError('two full golden frames did not pass')
            elif result.count('C40_CAPTURE_DIAGNOSTIC_STOP ')!=1:raise AssertionError('missing diagnostic stop')
            print(result[result.index('C40_CAPTURE_ROW ') if 'C40_CAPTURE_ROW ' in result else 0:],flush=True)
    print('C40_CAPTURE_DIAGNOSTIC_DONE temporary_removed=1 actual_CPU_IP=0',flush=True)


if __name__=='__main__':main()

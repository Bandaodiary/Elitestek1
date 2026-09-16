"""Run the generated, vendor-supported Mentor CPU model; do not modify IP."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
from c37_sources import ROOT
from run_c37_leaf_probe import budget
from c39_seam_admission import check
from c39_sapphire_platform_contract import audit

TOOLS=Path('D:/quartus/QTS/questa_fse/win64')
CPU=ROOT/'efinity/c39_cpu_s2_generate_20260915a'


def main():
    ap=argparse.ArgumentParser()
    ap.add_argument('--log-dir',type=Path,required=True)
    args=ap.parse_args()
    log=args.log_dir.resolve()
    if not log.is_relative_to(ROOT/'logs/c40_100mhz_runs') or not log.is_dir():
        raise ValueError('private log directory required')
    budget();check();contract=audit(CPU,('onehot_cdc',))
    vendor=CPU/'ip/c39_soc_s2/Testbench'
    env=dict(os.environ)
    # Current-process binding for the installed 2023.3 license client.
    if not env.get('MGLS_LICENSE_FILE') and env.get('SALT_LICENSE_FILE'):
        env['MGLS_LICENSE_FILE']=env['SALT_LICENSE_FILE']
    commands=[]
    with tempfile.TemporaryDirectory(prefix='c40_sapphire_',dir=ROOT/'sim') as temp:
        work=Path(temp)
        inputs=[]
        for path in vendor.iterdir():
            if path.is_file() and path.suffix.lower() in ('.v','.vh','.txt','.bin'):
                shutil.copyfile(path,work/path.name)
                inputs.append(str(path))
        # The official modelsim.do selects this simulator-specific protected file.
        specific=vendor/'modelsim/c39_soc_s2.v'
        shutil.copyfile(specific,work/'c39_soc_s2.v')
        inputs=[x for x in inputs if x!=str(vendor/'c39_soc_s2.v')]+[str(specific)]
        observer='''`timescale 1ns/1ps
module c40_clock_observer;
    realtime previous_edge=0;
    integer edges=0;
    always @(posedge tb_soc.io_systemClk) begin
        if(edges>0 && (($realtime-previous_edge<9.9995)||($realtime-previous_edge>10.0005)))
            $fatal(1,"C40 actual CPU system clock mismatch");
        previous_edge=$realtime;edges=edges+1;
        if(edges==1024)$display("C40_SAPPHIRE_CLOCK_PASS measured_core_hz=100000000 edges=1024");
    end
endmodule
'''
        (work/'c40_clock_observer.sv').write_text(observer,encoding='utf-8')
        (log/'clock_observer.sv').write_text(observer,encoding='utf-8')
        (log/'sources.json').write_text(json.dumps(dict(vendor_inputs=inputs,platform_contract=contract,
            protected_payload_exported=False),indent=2),encoding='utf-8')
        def run(name,command,timeout):
            commands.append(dict(step=name,command=command))
            (log/'commands.json').write_text(json.dumps(commands,indent=2),encoding='utf-8')
            result=subprocess.run(command,cwd=work,env=env,capture_output=True,text=True,
                encoding='utf-8',errors='replace',timeout=timeout)
            (log/f'{name}.stdout.log').write_text(result.stdout,encoding='utf-8')
            (log/f'{name}.stderr.log').write_text(result.stderr,encoding='utf-8')
            print('C40_SAPPHIRE_STEP '+json.dumps(dict(step=name,exit_code=result.returncode)),flush=True)
            if result.returncode:
                lines=[s for s in (result.stdout+result.stderr).splitlines() if any(k in s.lower() for k in ('error','fatal','license'))]
                raise RuntimeError('\n'.join(lines[:15]) or (result.stdout+result.stderr)[-1800:])
            return result.stdout+result.stderr
        run('vlib',[str(TOOLS/'vlib.exe'),'work'],60)
        design=[str(p.name) for p in sorted(work.glob('*.v'))]+['c40_clock_observer.sv']
        run('vlog',[str(TOOLS/'vlog.exe'),'-sv','+define+EFX_SIM',*design],300)
        result=run('vsim',[str(TOOLS/'vsim.exe'),'-c','-onfinish','exit','-wlf','NUL',
            'work.tb_soc','work.c40_clock_observer','-do',
            'onbreak {quit -code 1}; onerror {quit -code 2}; run 10 ms; quit -code 3'],1800)
        if '[EFX_INFO]: TEST PASSED' not in result or 'C40_SAPPHIRE_CLOCK_PASS ' not in result or '[EFX_FATAL]' in result:
            raise AssertionError('Actual CPU UART/clock completion missing')
    summary=dict(actual_CPU_IP=True,cpu_profile='Sapphire 3.4.1 S2',core_hz=100000000,
        official_UART_hello_world_pass=True,clock_measured=True,accelerator_connected=False,
        official_joint_throughput_verified=False,temporary_removed=not work.exists(),waveforms=False)
    (log/'summary.json').write_text(json.dumps(summary,indent=2),encoding='utf-8')
    print('C40_SAPPHIRE_BOOT_PASS temporary_removed=1 actual_CPU_IP=1',flush=True)


if __name__=='__main__':main()

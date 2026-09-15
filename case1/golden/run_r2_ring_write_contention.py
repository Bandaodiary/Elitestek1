"""C34/C33 actual write-fabric comparison; execute through detached runner only."""
from __future__ import annotations
import argparse
import json
from pathlib import Path
import re
import subprocess
import tempfile

import run_r2_credit_write_contention as retained

ROOT=retained.ROOT
TOP='tb_c1_r2_ring_write_contention'
SOURCES=tuple(s for s in retained.SOURCES if not s.endswith('/'+retained.TOP+'.sv'))+(
    'rtl/r2/c1_r2_tensor_credit_ring_writer.sv',f'sim/{TOP}.sv')
EXTRA={'input_gap','space_waits','wraps','peak_used','simultaneous_reserve_read'}


def parse_result(text,params):
    assert not re.search(r'FATAL|ERROR:|Traceback|RuntimeError',text)
    lines=[s for s in text.splitlines() if s.startswith('C34_WRITE_AXI_PASS ')]
    assert len(lines)==1,'missing/duplicate completion'
    fields={}
    for token in lines[0].split()[1:]:
        assert re.fullmatch(r'[A-Za-z_]+=-?\d+',token)
        key,value=token.split('=');assert key not in fields;fields[key]=int(value)
    assert set(fields)==retained.FIELDS|EXTRA
    reduced='C33_WRITE_AXI_PASS '+' '.join(f'{k}={v}' for k,v in fields.items() if k not in EXTRA)
    retained.parse_result(reduced,params)
    assert fields['input_gap']==params['INPUT_GAP']
    if params['CANDIDATE']==3:
        assert 0<fields['peak_used']<=1024
        assert all(fields[k]>=0 for k in EXTRA)
    else:assert fields['peak_used']==fields['space_waits']==fields['wraps']==fields['simultaneous_reserve_read']==0
    return fields


def simulate(folder,shape,candidate,aw,error=0,gap=0,refill=0,negative=None):
    mode,channels,width=shape
    pp,ee,npack,nlogical,nphysical=retained.fixture(*shape)
    (folder/'packets.mem').write_text(''.join(f'{v:018x}\n' for v in pp),encoding='ascii')
    (folder/'physical.mem').write_text(''.join(f'{v:032x}\n' for v in ee),encoding='ascii')
    params=dict(CANDIDATE=candidate,MODE=mode,CHANNELS=channels,WIDTH=width,
                PACKETS=npack,WORDS=nlogical,PHYSICAL_WORDS=nphysical,AW_WAIT_W=aw,
                INJECT_B=error,FORCE_REFILL=refill,INPUT_GAP=gap,START_GAP=0 if gap==0 else 128)
    if negative:params[negative]=1
    exe=folder/'ring.vvp'
    c=subprocess.run(['D:/iverilog/bin/iverilog.exe','-g2012','-s',TOP,
        *[f'-P{TOP}.{k}={v}' for k,v in params.items()],'-o',str(exe),
        *[str(ROOT/s) for s in SOURCES]],capture_output=True,text=True,timeout=60)
    if c.returncode:
        raise RuntimeError('\n'.join(line for line in c.stderr.splitlines() if 'warning:' not in line and 'sorry:' not in line)[-3000:])
    r=subprocess.run(['D:/iverilog/bin/vvp.exe',str(exe),f'+DIR={folder.as_posix()}'],capture_output=True,text=True,timeout=120)
    output=r.stdout+r.stderr
    if negative:
        reason={'BREAK_CREDIT':'C33 grant exceeds published logical words',
                'BREAK_DRAIN':'C33 authorized burst failed to drain during refill'}[negative]
        assert r.returncode!=0 and reason in output and 'C34_WRITE_AXI_PASS ' not in output,(params,output[-3000:])
        print('C34_WRITE_AXI_NEGATIVE_PASS '+json.dumps(dict(control=negative,actual_RTL_rejected=True,reason=reason),separators=(',',':')),flush=True)
        return
    if r.returncode:raise RuntimeError(str(params)+'\n'+output[-3000:])
    result=parse_result(output,params)
    for line in output.splitlines():
        if line.startswith('C34_WRITE_AXI_'):print(line,flush=True)
    return result


def main():
    p=argparse.ArgumentParser();p.add_argument('--temporary-parent',type=Path,required=True)
    a=p.parse_args();parent=a.temporary_parent.resolve()
    assert parent.is_dir() and parent.is_relative_to((ROOT/'sim').resolve())
    peer=subprocess.run(['powershell.exe','-NoProfile','-NonInteractive','-Command',
        "@(Get-Process -Name xsim,xsimk,xelab,xvlog,vvp,iverilog,efx_map,efx_pnr -ErrorAction SilentlyContinue).Count"],capture_output=True,text=True,timeout=20)
    assert peer.returncode==0 and peer.stdout.strip()=='0','another heavy FPGA task is active'
    results=[];comparisons=[]
    with tempfile.TemporaryDirectory(prefix='c1_r2_ring_',dir=parent) as td:
        folder=Path(td)
        for shape in retained.SHAPES:
            for aw in (0,2):
                for error in (0,1):
                    for gap in (0,8):
                        pair=[simulate(folder,shape,candidate,aw,error,gap) for candidate in (2,3)]
                        results.extend(pair)
                        comparison=dict(mode=shape[0],aw_wait_w=aw,inject_b=error,input_gap=gap,
                            capture_wait=[r['capture_command_wait_max'] for r in pair],
                            empty_head=[r['blocked_empty_head'] for r in pair],
                            producer_span=[r['nn_span_cycles'] for r in pair],full_host_fps_claim=False)
                        comparisons.append(comparison)
                        print('C34_WRITE_AXI_COMPARE '+json.dumps(comparison,separators=(',',':')),flush=True)
        for shape in retained.BOUNDARIES:
            for aw in (0,2):
                for candidate in (2,3):results.append(simulate(folder,shape,candidate,aw))
        for shape in retained.REFILL_SHAPES:
            for aw in (0,2):
                for candidate in (2,3):results.append(simulate(folder,shape,candidate,aw,gap=8,refill=1))
        simulate(folder,retained.SHAPES[0],3,2,gap=8,negative='BREAK_CREDIT')
        simulate(folder,retained.SHAPES[0],3,2,gap=8,refill=1,negative='BREAK_DRAIN')
        ring=[r for r in results if r['candidate']==3]
        assert max(r['peak_used'] for r in ring)==1024,'full ring not exercised'
        assert sum(r['wraps'] for r in ring)>0,'physical row wrapping not exercised'
        assert sum(r['space_waits'] for r in ring)>0,'space reservation backpressure not exercised'
        print('C34_WRITE_AXI_SUMMARY '+json.dumps(dict(configurations=len(results),comparisons=len(comparisons),
            peak_reserved_words=max(r['peak_used'] for r in ring),wrap_events=sum(r['wraps'] for r in ring),
            space_stall_cycles=sum(r['space_waits'] for r in ring),actual_negative_controls=2,
            physical_words=sum(r['nn_words']+r['capture_words'] for r in results),
            physical_bursts=sum(r['aw'] for r in results),full_host_fps_claim=False),separators=(',',':')),flush=True)
    print('C34_WRITE_AXI_CLEAN temporary_vectors_and_simulator_removed=1',flush=True)


if __name__=='__main__':main()

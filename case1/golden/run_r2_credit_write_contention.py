"""C33 real write-fabric comparison with independent byte oracle and fault controls.

Run through run_r2_credit_write_contention_detached.ps1. No camera/read/CPU/CNN
operators are instantiated: write-side latency is not a whole-host FPS result.
"""
from __future__ import annotations
import argparse
import json
from pathlib import Path
import re
import subprocess
import tempfile

from run_r2_cutthrough_writer_probe import ROOT, packets, expected_words
from run_r2_cutthrough_write_contention import FIELDS as OLD_FIELDS, expected_bursts

TOP='tb_c1_r2_credit_write_contention'
SHAPES=((0,24,32),(1,3,64),(2,24,32))
REFILL_SHAPES=((0,24,32),(1,3,128),(2,24,32))
BOUNDARIES=((0,16,1024),(2,24,640),(2,48,3),(1,3,3),
            (0,48,32),(3,24,16),(4,12,16),(5,24,16))
SOURCES=('rtl/common/c1_ram_sdp_read_first.sv',
         'rtl/r2/c1_r2_tensor_pingpong_writer.sv',
         'rtl/r2/c1_r2_tensor_cutthrough_writer.sv',
         'rtl/r2/c1_r2_tensor_burst_credit_writer.sv',
         'rtl/r2/c1_r2_axi_row_write.sv','rtl/r2/c1_r2_rgbx_row_write.sv',
         'rtl/r2/c1_r2_axi_credit_row_write.sv','rtl/r2/c1_r2_rgbx_credit_row_write.sv',
         'rtl/dma/c1_axi_n_write_burst_arbiter_128.sv',
         'sim/c1_r2_axi_memory_bfm.sv',f'sim/{TOP}.sv')
FIELDS=OLD_FIELDS|{'force_refill','refill_fetches','refill_wlast'}


def fixture(mode,channels,width):
    producer=[word for row in range(3) for word,_ in packets(mode,width,channels,row)]
    logical=[word for row in range(3) for word in expected_words(width,channels,row,mode==1)]
    if mode==1:
        physical=[sum(((((row*47+(x+p)*13+c*7+19)&255)^128) << (32*p+8*c))
                      for p in range(4) if x+p<width for c in range(3))
                  for row in range(3) for x in range(0,width,4)]
        assert len(logical)==2*len(physical),'RGB fixture needs an even logical word count'
        for i,value in enumerate(physical):
            for pixel in range(4):
                assert (value>>(pixel*32))&0xffffffff == (logical[2*i+pixel//2]>>((pixel%2)*64))&0xffffff
    else:physical=logical
    npack=len(producer)//3; nlogical=len(logical)//3; nphysical=len(physical)//3
    assert len(producer)==3*npack and len(logical)==3*nlogical and len(physical)==3*nphysical
    for row in range(3):
        assert producer[(row+1)*npack-1]>>70==1
        assert all(w>>70==0 for w in producer[row*npack:(row+1)*npack-1])
    assert physical[0]!=physical[nphysical]!=physical[2*nphysical]
    assert nlogical<=1024 and all(0<=v<1<<128 for v in physical)
    return producer,physical,npack,nlogical,nphysical


def parse_result(text,params):
    assert not re.search(r'FATAL|ERROR:|Traceback|RuntimeError',text),'runtime error'
    lines=[s for s in text.splitlines() if s.startswith('C33_WRITE_AXI_PASS ')]
    assert len(lines)==1,'missing/duplicate completion'
    result={}
    for token in lines[0].split()[1:]:
        assert re.fullmatch(r'[A-Za-z_]+=-?\d+',token),'malformed metric'
        key,value=token.split('=');assert key not in result;result[key]=int(value)
    assert set(result)==FIELDS,'metric schema differs'
    for name in ('candidate','mode','channels','width','aw_wait_w','inject_b','force_refill'):
        assert result[name]==params[name.upper()],f'configuration differs: {name}'
    assert result['nn_rows']==3 and result['capture_rows']==4
    assert result['nn_words']==params['PHYSICAL_WORDS']*3 and result['capture_words']==64
    assert result['aw']==result['b']==3*expected_bursts(params['PHYSICAL_WORDS'])+4
    assert result['nn_errors']==params['INJECT_B'] and result['capture_errors']==0
    assert result['actual_AXI']==1 and result['actual_camera']==result['whole_CNN']==0
    assert 0<=result['early_words']<=result['nn_words']
    if params['CANDIDATE']==0:assert result['early_words']==0
    if params['CANDIDATE']==1:assert result['early_words']>0 and result['blocked_empty_head']>0
    assert 0<=result['max_empty_run']<=result['blocked_empty_head']<=result['nn_span_cycles']
    for name in ('max_nn_w_occupancy','capture_command_wait_max','capture_due_wait_max','nn_admit_first_w_max','nn_span_cycles'):
        assert 0<result[name]<300000,f'invalid cycle measurement: {name}'
    if params['FORCE_REFILL']:assert result['refill_fetches']>0 and result['refill_wlast']>0
    else:assert result['refill_fetches']==result['refill_wlast']==0
    return result


def simulate(folder,shape,candidate=2,aw=2,error=0,refill=0,negative=None):
    mode,channels,width=shape
    pp,ee,npack,nlogical,nphysical=fixture(*shape)
    (folder/'packets.mem').write_text(''.join(f'{v:018x}\n' for v in pp),encoding='ascii')
    (folder/'physical.mem').write_text(''.join(f'{v:032x}\n' for v in ee),encoding='ascii')
    params=dict(CANDIDATE=candidate,MODE=mode,CHANNELS=channels,WIDTH=width,
                PACKETS=npack,WORDS=nlogical,PHYSICAL_WORDS=nphysical,
                AW_WAIT_W=aw,INJECT_B=error,FORCE_REFILL=refill)
    if negative:params[negative]=1
    exe=folder/'credit.vvp'
    compile_run=subprocess.run(['D:/iverilog/bin/iverilog.exe','-g2012','-s',TOP,
        *[f'-P{TOP}.{k}={v}' for k,v in params.items()],'-o',str(exe),
        *[str(ROOT/s) for s in SOURCES]],capture_output=True,text=True,timeout=60)
    if compile_run.returncode:
        raise RuntimeError('\n'.join(s for s in compile_run.stderr.splitlines() if 'sorry:' not in s and 'warning:' not in s)[-3000:])
    run=subprocess.run(['D:/iverilog/bin/vvp.exe',str(exe),f'+DIR={folder.as_posix()}'],capture_output=True,text=True,timeout=120)
    output=run.stdout+run.stderr
    if negative:
        expected={'BREAK_CREDIT':'C33 grant exceeds published logical words',
                  'BREAK_DRAIN':'C33 authorized burst failed to drain during refill'}[negative]
        assert run.returncode!=0 and expected in output and 'C33_WRITE_AXI_PASS ' not in output,(params,output[-3000:])
        print('C33_WRITE_AXI_NEGATIVE_PASS '+json.dumps(dict(control=negative,
              actual_RTL_rejected=True,reason=expected),separators=(',',':')),flush=True)
        return None
    if run.returncode:raise RuntimeError(str(params)+'\n'+output[-3000:])
    result=parse_result(output,params)
    for line in output.splitlines():
        if line.startswith('C33_WRITE_AXI_'):print(line,flush=True)
    return result


def main():
    p=argparse.ArgumentParser();p.add_argument('--temporary-parent',type=Path,required=True)
    a=p.parse_args();parent=a.temporary_parent.resolve()
    if not parent.is_relative_to((ROOT/'sim').resolve()) or not parent.is_dir():p.error('private directory outside case1/sim')
    peer=subprocess.run(['powershell.exe','-NoProfile','-NonInteractive','-Command',
        "@(Get-Process -Name xsim,xsimk,xelab,xvlog,vvp,iverilog,efx_map,efx_pnr -ErrorAction SilentlyContinue).Count"],capture_output=True,text=True,timeout=20)
    if peer.returncode or peer.stdout.strip()!='0':raise RuntimeError('another FPGA tool active')
    comparisons=[];results=[]
    with tempfile.TemporaryDirectory(prefix='c1_r2_credit_',dir=parent) as td:
        folder=Path(td)
        for shape in SHAPES:
            for aw in (0,2):
                for error in (0,1):
                    triplet=[simulate(folder,shape,candidate,aw,error) for candidate in (0,1,2)]
                    results.extend(triplet)
                    before,cutthrough,credit=triplet
                    comparison=dict(mode=shape[0],aw_wait_w=aw,inject_b=error,
                        capture_wait=[r['capture_command_wait_max'] for r in triplet],
                        empty_head=[r['blocked_empty_head'] for r in triplet],
                        w_occupancy=[r['max_nn_w_occupancy'] for r in triplet],
                        producer_span=[r['nn_span_cycles'] for r in triplet],full_host_fps_claim=False)
                    comparisons.append(comparison)
                    print('C33_WRITE_AXI_COMPARE '+json.dumps(comparison,separators=(',',':')),flush=True)
        for shape in REFILL_SHAPES:
            for aw in (0,2):results.append(simulate(folder,shape,aw=aw,refill=1))
        for shape in BOUNDARIES:
            for aw in (0,2):results.append(simulate(folder,shape,aw=aw))
        simulate(folder,SHAPES[0],negative='BREAK_CREDIT')
        simulate(folder,SHAPES[0],refill=1,negative='BREAK_DRAIN')
        print('C33_WRITE_AXI_SUMMARY '+json.dumps(dict(configurations=len(results),comparisons=len(comparisons),
            forced_refill_configurations=6,boundary_configurations=16,actual_negative_controls=2,
            physical_words=sum(r['nn_words']+r['capture_words'] for r in results),
            physical_bursts=sum(r['aw'] for r in results),
            c33_less_empty_head_than_c32=all(c['empty_head'][2]<c['empty_head'][1] for c in comparisons),
            c33_capture_no_worse_than_c31=all(c['capture_wait'][2]<=c['capture_wait'][0] for c in comparisons),
            full_host_fps_claim=False),separators=(',',':')),flush=True)
    print('C33_WRITE_AXI_CLEAN temporary_vectors_and_simulator_removed=1',flush=True)


if __name__=='__main__':main()

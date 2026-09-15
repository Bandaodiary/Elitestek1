"""C32 actual AXI two-writer probe, deliberately NOT a full camera/CNN test.

--oracle-only prepares/checks tiny fixtures in memory; it never runs RTL.
Actual simulation is deferred until the isolated writer gate passes and the
single-heavy-worker detached runner can acquire the workload budget.
"""
from __future__ import annotations
import argparse
import json
from pathlib import Path
import re
import subprocess
import tempfile

from run_r2_cutthrough_writer_probe import ROOT, packets, expected_words

TOP='tb_c1_r2_cutthrough_write_contention'
SHAPES=((0,24,32),(1,3,64),(2,24,32))
SOURCES=('rtl/common/c1_ram_sdp_read_first.sv',
         'rtl/r2/c1_r2_tensor_pingpong_writer.sv',
         'rtl/r2/c1_r2_tensor_cutthrough_writer.sv',
         'rtl/r2/c1_r2_axi_row_write.sv','rtl/r2/c1_r2_rgbx_row_write.sv',
         'rtl/dma/c1_axi_n_write_burst_arbiter_128.sv',
         'sim/c1_r2_axi_memory_bfm.sv',f'sim/{TOP}.sv')
FIELDS=set(('candidate mode channels width aw_wait_w inject_b nn_rows capture_rows '
            'nn_words capture_words aw b early_words blocked_empty_head max_empty_run '
            'max_nn_w_occupancy capture_command_wait_max capture_due_wait_max '
            'nn_admit_first_w_max nn_span_cycles nn_errors capture_errors '
            'actual_AXI actual_camera whole_CNN').split())


def fixture(mode,channels,width):
    producer=[word for row in range(3) for word,_ in packets(mode,width,channels,row)]
    logical=[word for row in range(3) for word in expected_words(width,channels,row,mode==1)]
    if mode==1:
        # Direct pixel-coordinate RGBX oracle, not the RTL's half-word slices.
        physical=[sum(((((row*47+(x+p)*13+c*7+19)&255)^128) << (32*p+8*c))
                      for p in range(4) for c in range(3))
                  for row in range(3) for x in range(0,width,4)]
        # Independently check the two already verified logical P2C8 words
        # correspond to exactly these four RGBX pixels, including zero X.
        for i,value in enumerate(physical):
            pair=logical[2*i:2*i+2]
            for pixel in range(4):
                assert (value>>(pixel*32))&0xffffffff == (pair[pixel//2]>>((pixel%2)*64))&0xffffff
    else:physical=logical
    per_packets=len(producer)//3;per_words=len(logical)//3
    assert sum(word>>70 for word in producer)==3
    for row in range(3):
        assert producer[(row+1)*per_packets-1]>>70==1
        assert all(word>>70==0 for word in producer[row*per_packets:(row+1)*per_packets-1])
    assert len(physical)%3==0 and len(set(physical[:len(physical)//3]))>1
    assert physical[0]!=physical[len(physical)//3]!=physical[2*len(physical)//3]
    assert all(0<=w<1<<128 for w in physical)
    return producer,physical,per_packets,per_words,len(physical)//3


def expected_bursts(words):
    # All fixtures start 16 bytes before a 4KiB boundary. Subsequent bursts
    # are capped at 16 words. This is independent of the DMA cursor equations.
    return 1+(max(0,words-1)+15)//16


def parse_result(text,mode,channels,width,candidate,aw,error,physical_words):
    if re.search(r'FATAL|ERROR:|Traceback|RuntimeError',text):raise AssertionError('AXI runtime failure')
    lines=[line for line in text.splitlines() if line.startswith('C32_WRITE_AXI_PASS ')]
    assert len(lines)==1,'missing/duplicate AXI completion'
    row={}
    for token in lines[0].split()[1:]:
        assert re.fullmatch(r'[A-Za-z_]+=-?\d+',token),'malformed AXI metric'
        key,value=token.split('=');assert key not in row,'duplicate AXI field';row[key]=int(value)
    assert set(row)==FIELDS,'AXI evidence fields differ'
    assert [row[k] for k in ('candidate','mode','channels','width','aw_wait_w','inject_b')]==[candidate,mode,channels,width,aw,error]
    assert row['nn_rows']==3 and row['capture_rows']==4
    assert row['nn_words']==physical_words*3 and row['capture_words']==64
    assert row['aw']==row['b']==3*expected_bursts(physical_words)+4
    assert row['nn_errors']==error and row['capture_errors']==0
    assert row['actual_AXI']==1 and row['actual_camera']==row['whole_CNN']==0
    assert 0<=row['early_words']<=row['nn_words']
    if candidate:
        assert row['early_words']>0 and row['blocked_empty_head']>0,'slow-producer head-of-line test was not exercised'
    else:assert row['early_words']==0
    assert 0<=row['max_empty_run']<=row['blocked_empty_head']<=row['nn_span_cycles']
    for name in ('max_nn_w_occupancy','capture_command_wait_max','capture_due_wait_max','nn_admit_first_w_max','nn_span_cycles'):
        assert 0<row[name]<100000,'invalid/missing AXI cycle observation'
    return row


def oracle_only():
    packets_total=physical_total=0
    for shape in SHAPES:
        pp,ee,packet_count,logical_words,physical_words=fixture(*shape)
        assert len(pp)==3*packet_count and len(ee)==3*physical_words
        assert physical_words==(logical_words//2 if shape[0]==1 else logical_words)
        packets_total+=len(pp);physical_total+=len(ee)
    print('C32_WRITE_AXI_ORACLE_PASS '+json.dumps(dict(shapes=3,configurations=24,
          unique_producer_packets=packets_total,unique_physical_words=physical_total,
          actual_RTL_compiled=False,actual_RTL_simulated=False,whole_CNN_fps_claim=False),separators=(',',':')),flush=True)


def main():
    p=argparse.ArgumentParser();p.add_argument('--oracle-only',action='store_true')
    p.add_argument('--temporary-parent',type=Path,default=ROOT/'sim')
    a=p.parse_args();oracle_only()
    if a.oracle_only:return
    parent=a.temporary_parent.resolve()
    if not parent.is_relative_to((ROOT/'sim').resolve()) or not parent.is_dir():p.error('private parent must be within case1/sim')
    peer=subprocess.run(['powershell.exe','-NoProfile','-NonInteractive','-Command',
        "@(Get-Process -Name xsim,xsimk,xelab,xvlog,vvp,iverilog,efx_map,efx_pnr -ErrorAction SilentlyContinue).Count"],capture_output=True,text=True,timeout=20)
    if peer.returncode or peer.stdout.strip()!='0':raise RuntimeError('another FPGA tool active; defer AXI test')
    with tempfile.TemporaryDirectory(prefix='c1_r2_write_contention_',dir=parent) as td:
        folder=Path(td)
        for mode,channels,width in SHAPES:
            pp,ee,npack,nlogical,nphysical=fixture(mode,channels,width)
            (folder/'packets.mem').write_text(''.join(f'{v:018x}\n' for v in pp),encoding='ascii')
            (folder/'physical.mem').write_text(''.join(f'{v:032x}\n' for v in ee),encoding='ascii')
            for aw in (0,2):
                for error in (0,1):
                    pair=[]
                    for candidate in (0,1):
                        params=dict(CANDIDATE=candidate,MODE=mode,CHANNELS=channels,WIDTH=width,
                            PACKETS=npack,WORDS=nlogical,PHYSICAL_WORDS=nphysical,AW_WAIT_W=aw,INJECT_B=error)
                        exe=folder/'contention.vvp'
                        c=subprocess.run(['D:/iverilog/bin/iverilog.exe','-g2012','-s',TOP,
                            *[f'-P{TOP}.{k}={v}' for k,v in params.items()],'-o',str(exe),*[str(ROOT/s) for s in SOURCES]],capture_output=True,text=True,timeout=60)
                        if c.returncode:
                            raise RuntimeError('\n'.join(line for line in c.stderr.splitlines() if 'warning:' not in line and 'sorry:' not in line)[-3000:])
                        r=subprocess.run(['D:/iverilog/bin/vvp.exe',str(exe),f'+DIR={folder.as_posix()}'],capture_output=True,text=True,timeout=60)
                        if r.returncode:raise RuntimeError((r.stdout+r.stderr)[-3000:])
                        result=parse_result(r.stdout,mode,channels,width,candidate,aw,error,nphysical)
                        pair.append(result)
                        for line in r.stdout.splitlines():
                            if line.startswith('C32_WRITE_AXI_'):print(line,flush=True)
                    before,after=pair
                    # Report the signed observation. Do not require a speedup
                    # and do not relabel a write-only probe as full-host FPS.
                    print('C32_WRITE_AXI_COMPARE '+json.dumps(dict(mode=mode,aw_wait_w=aw,inject_b=error,
                        capture_wait_delta=after['capture_command_wait_max']-before['capture_command_wait_max'],
                        empty_head_delta=after['blocked_empty_head']-before['blocked_empty_head'],
                        producer_row_span_delta=after['nn_span_cycles']-before['nn_span_cycles'],
                        full_host_fps_claim=False),separators=(',',':')),flush=True)
    print('C32_WRITE_AXI_CLEAN temporary_vectors_and_simulator_removed=1',flush=True)


if __name__=='__main__':main()

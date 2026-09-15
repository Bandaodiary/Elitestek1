"""C32 independent writer: byte-publication model and deferred actual RTL tests.

--model-only is a lightweight mathematical ordering check, NOT RTL simulation.
The default runs two real writers against independently packed expected words.
"""
import argparse
import json
import subprocess
import tempfile
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
CASES=[(0,8),(0,16),(0,24),(0,48),(1,3),(2,16),(2,24),(2,48),(3,24),(4,12),(5,24)]


def packets(mode,width,channels,row):
    def value(x,c):return (row*47+x*13+c*7+19)&255
    result=[]
    if mode==2:
        for x in range(0,width,2):
            for g in range((channels+7)//8):
                for phase in range(3):
                    lanes=[(x+(phase*6+l)//8,g*8+(phase*6+l)%8)
                           if phase*6+l<16 else None for l in range(6)]
                    result.append(((x<<5)|(g<<2)|phase,lanes))
    elif mode==1:
        for x in range(0,width,2):result.append((x,[(x+l//3,l%3) for l in range(6)]))
    else:
        for scalar in range(0,width*channels,6):
            result.append((scalar,[((scalar+l)//channels,(scalar+l)%channels) for l in range(6)]))
    for k,(index,lanes) in enumerate(result):
        lanes=[p if p is not None and p[0]<width and p[1]<channels else None for p in lanes]
        mask=sum(1<<l for l,p in enumerate(lanes) if p is not None)
        data=sum(value(*p)<<(8*l) for l,p in enumerate(lanes) if p is not None)
        yield (int(k==len(result)-1)<<70)|(index<<54)|(mask<<48)|data,lanes


def expected_words(width,channels,row,rgb):
    for x in range(0,width,2):
        for g in range((channels+7)//8):
            value=0
            for lane in range(16):
                px=x+lane//8;ch=g*8+lane%8
                if px<width and ch<channels:
                    value|=(((row*47+px*13+ch*7+19)&255)^(128 if rgb else 0))<<(8*lane)
            yield value


def model_check(mode,width,channels):
    groups=(channels+7)//8;words=((width+1)//2)*groups
    seen=[set() for _ in range(words)]
    needed=[{(x+p,g*8+c) for p in range(2) for c in range(8)
             if x+p<width and g*8+c<channels}
            for x in range(0,width,2) for g in range(groups)]
    prefix=0;early=0;count=0
    for packed,lanes in packets(mode,width,channels,0):
        finish=[]
        for p in lanes:
            if p is None:continue
            x,c=p;word=(x//2)*groups+c//8
            assert word>=prefix and p not in seen[word], 'revisited published/duplicate byte'
            seen[word].add(p)
            if (x%2==1 or x+1==width) and (c%8==7 or c+1==channels):finish.append(word)
        # Independent oracle is the full set of actual valid bytes, not the
        # RTL's last-coordinate predicate or an assumed packet count.
        oracle=prefix
        while oracle<words and seen[oracle]==needed[oracle]:oracle+=1
        assert finish==list(range(prefix,oracle)), 'last-byte predicate differs from full-byte oracle'
        prefix+=len(finish);count+=1
        if prefix and not (packed>>70):early+=1
    assert prefix==words and all(a==b for a,b in zip(seen,needed))
    return count,early


def main():
    p=argparse.ArgumentParser();p.add_argument('--model-only',action='store_true')
    p.add_argument('--temporary-parent',type=Path,default=ROOT/'sim')
    a=p.parse_args();cases=packet_count=early=0
    for mode,channels in CASES:
        for width in (1,2,3,4,7,16,31,160,320,640,1024):
            if ((width+1)//2)*((channels+7)//8)>1024:continue
            n,e=model_check(mode,width,channels);cases+=1;packet_count+=n;early+=e
    print(f'C32_WRITER_ORDER_MODEL_PASS shapes={cases} producer_packets={packet_count} early_prefix_events={early} complete_byte_set_oracle=1 RTL_simulated=0',flush=True)
    if a.model_only:return
    # Refuse concurrent simulations/PNR; run from the budgeted detached worker.
    peer=subprocess.run(['powershell.exe','-NoProfile','-NonInteractive','-Command',
        "@(Get-Process -Name xsim,xsimk,xelab,vvp,efx_map,efx_pnr -ErrorAction SilentlyContinue).Count"],
        capture_output=True,text=True,timeout=20)
    if peer.returncode or peer.stdout.strip()!='0':raise RuntimeError('another FPGA tool active; defer C32 simulation')
    parent=a.temporary_parent.resolve()
    if not parent.is_relative_to((ROOT/'sim').resolve()) or not parent.is_dir():p.error('private parent must be within case1/sim')
    configs=[(m,c,w) for m,c in CASES for w in (3,16)]
    with tempfile.TemporaryDirectory(prefix='c1_r2_cutthrough_',dir=parent) as td:
        folder=Path(td)
        for number,(mode,channels,width) in enumerate(configs):
            pp=[word for row in range(4) for word,_ in packets(mode,width,channels,row)]
            ee=[word for row in range(4) for word in expected_words(width,channels,row,mode==1)]
            (folder/'packets.mem').write_text(''.join(f'{v:018x}\n' for v in pp),encoding='ascii')
            (folder/'expected.mem').write_text(''.join(f'{v:032x}\n' for v in ee),encoding='ascii')
            top='tb_c1_r2_tensor_cutthrough_writer';exe=folder/'writer.vvp'
            params=dict(MODE=mode,CHANNELS=channels,WIDTH=width,PACKETS=len(pp)//4,WORDS=len(ee)//4,ROWS=4)
            sources=['rtl/common/c1_ram_sdp_read_first.sv','rtl/r2/c1_r2_tensor_pingpong_writer.sv',
                     'rtl/r2/c1_r2_tensor_cutthrough_writer.sv',f'sim/{top}.sv']
            c=subprocess.run(['D:/iverilog/bin/iverilog.exe','-g2012','-s',top,
                *[f'-P{top}.{k}={v}' for k,v in params.items()],'-o',str(exe),*[str(ROOT/s) for s in sources]],
                capture_output=True,text=True,timeout=60)
            if c.returncode:raise RuntimeError('\n'.join(x for x in c.stderr.splitlines() if 'warning:' not in x and 'sorry:' not in x)[-3000:])
            r=subprocess.run(['D:/iverilog/bin/vvp.exe',str(exe),f'+DIR={folder.as_posix()}'],capture_output=True,text=True,timeout=60)
            if r.returncode or r.stdout.count('C32_WRITER_RTL_PASS ')!=1:raise RuntimeError((r.stdout+r.stderr)[-3000:])
            for line in r.stdout.splitlines():
                if line.startswith('C32_'):print(line,flush=True)
    print('C32_WRITER_CLEAN temporary_vectors_and_simulator_removed=1',flush=True)


if __name__=='__main__':main()

"""C34 word-reservation model, independent absolute FIFO ownership oracle.

This checks the proposed allocation contract and source footprint only.
It does not compile RTL, exercise byte-lane packing or prove an FPGA RAM count.
"""
from collections import deque
import json
from pathlib import Path
import random

ROOT=Path(__file__).resolve().parents[1]


def trial(seed,capacity,rows_target=48):
    rng=random.Random(seed)
    # Absolute positions and per-slot owners are the oracle. The candidate
    # accounting is deliberately separate from this unbounded FIFO sequence.
    cells=[None]*capacity
    rows=deque();allocated=retired=tail_abs=head_abs=used=0
    held=None;wraps=blocked=read_reuse=simultaneous=0;peak=0
    shapes=(1024,1024,960,640,480,320,240,24,16,3,1)
    for cycle in range(1000000):
        current=rows[-1] if rows and not rows[-1]['produced_last'] else None
        length=shapes[allocated%len(shapes)]
        wants=allocated<rows_target and current is None and len(rows)<2
        reserve=wants and used+length<=capacity
        if wants and not reserve:blocked+=1
        consume=held is not None and rng.randrange(4)!=0
        if consume:
            absolute,value=held
            assert value==(absolute*47+seed*19)&0xffffffffffffffff
            assert rows[0]['base']<=absolute<rows[0]['base']+rows[0]['length']
            rows[0]['delivered']+=1;held=None
        # Start the 2048-word reference with two complete reservations before
        # allowing reads, explicitly covering a truly full physical buffer.
        allow_fetch=capacity==1024 or allocated>=2
        fetch=bool(allow_fetch and rows and rows[0]['read']<rows[0]['published'] and held is None and rng.randrange(4)!=0)
        if reserve:
            base=tail_abs
            if base%capacity+length>capacity:wraps+=1
            # Full-row reservation: check physical non-overlap before ANY
            # producer byte is allowed to alter these addresses.
            for absolute in range(base,base+length):
                physical=absolute%capacity
                assert cells[physical] is None,'unread word overwritten by row reservation'
                cells[physical]=[absolute,None]
            rows.append(dict(base=base,length=length,published=0,read=0,delivered=0,
                             produced_last=False,b_due=cycle+rng.randrange(5,90)))
            tail_abs+=length;allocated+=1
            if len(rows)>1 and rows[0]['read']>0:read_reuse+=1
        if fetch:
            row=rows[0];absolute=row['base']+row['read']
            assert absolute==head_abs
            physical=absolute%capacity
            assert cells[physical] is not None and cells[physical][0]==absolute
            value=cells[physical][1];assert value is not None,'unpublished word read'
            held=(absolute,value);cells[physical]=None;row['read']+=1;head_abs+=1
        used+=(length if reserve else 0)-int(fetch)
        simultaneous+=int(reserve and fetch);peak=max(peak,used)
        assert 0<=used<=capacity and used==tail_abs-head_abs
        # A held RAM read is independent of later writes reusing its address.
        if held is not None:assert held[1]==(held[0]*47+seed*19)&0xffffffffffffffff
        current=rows[-1] if rows and not rows[-1]['produced_last'] else None
        if current is not None:
            count=min(rng.randrange(1,7),current['length']-current['published'])
            for index in range(current['published'],current['published']+count):
                absolute=current['base']+index;physical=absolute%capacity
                assert cells[physical] is not None and cells[physical][0]==absolute
                cells[physical][1]=(absolute*47+seed*19)&0xffffffffffffffff
            current['published']+=count
            # Model an empty tail that may follow the last valid data word.
            if current['published']==current['length'] and rng.randrange(5)==0:current['produced_last']=True
        if rows:
            first=rows[0]
            if first['produced_last'] and first['delivered']==first['length'] and cycle>=first['b_due']:
                rows.popleft();retired+=1
        if retired==rows_target:
            assert allocated==retired and used==0 and held is None and all(x is None for x in cells)
            assert peak==capacity and wraps>0 and read_reuse>0 and simultaneous>0,dict(seed=seed,capacity=capacity,peak=peak,wraps=wraps,read_reuse=read_reuse,simultaneous=simultaneous)
            return dict(rows=retired,words=head_abs,wraps=wraps,blocked=blocked,
                        simultaneous=simultaneous,read_reuse=read_reuse,peak=peak)
    raise AssertionError('word model did not drain')


def main():
    source=(ROOT/'rtl/r2/c1_r2_tensor_credit_ring_writer.sv').read_text(encoding='utf-8-sig')
    assert 'parameter integer STORAGE_WORDS=1024' in source
    assert source.count('c1_ram_sdp_read_first #(')==1 and 'b<16' in source
    assert '.DEPTH(STORAGE_WORDS),.ADDR_WIDTH(RAM_AW)' in source
    assert '.rd_addr(send_ram_address)' in source and '.wr_addr(addr)' in source
    assert 'requested_words!=0 && reserve_end<=STORAGE_WORDS' in source
    result=[trial(seed,capacity) for capacity in (1024,2048) for seed in range(8)]
    print('C34_RING_MODEL_PASS '+json.dumps(dict(trials=len(result),rows=sum(r['rows'] for r in result),
        words=sum(r['words'] for r in result),wraps=sum(r['wraps'] for r in result),
        space_stalls=sum(r['blocked'] for r in result),simultaneous_events=sum(r['simultaneous'] for r in result),
        reuse_before_row_B=sum(r['read_reuse'] for r in result),source_default_bytes=16*1024,
        baseline_bytes=16*2048,RTL_compiled=False,RTL_simulated=False,FPGA_resource_measured=False),separators=(',',':')))


if __name__=='__main__':main()

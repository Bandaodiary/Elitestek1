"""C35 physical-address model for row-fused DW16/PW8 using existing 16KiB.

Current overlay splits spatial address bit9 into two halves. The candidate
instead selects the half with bit0 and uses bits9:1 for its 512-word address.
This is a bijective spatial repacking, NOT a modification of retained RTL.
"""
import json
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]


def spatial_cell(parity,address,word,repacked):
    assert parity in (0,1) and 0<=address<1024 and word in (0,1)
    half=(address&1) if repacked else (address>>9)
    slot=(address>>1) if repacked else (address&511)
    return parity*4+half*2+word,slot


def input_cells(frame_width,repacked):
    assert 4<=frame_width<=640 and frame_width%4==0
    native_width=frame_width//2
    logical_words=(native_width//2)*2  # C16: two channel groups per pixel pair.
    return {spatial_cell(p,a,w,repacked) for p in (0,1) for a in range(logical_words) for w in (0,1)}


def output_cells(frame_width,base):
    return {(bank,address) for bank in range(8) for address in range(base,base+frame_width//2)}


def proof(frame_width):
    inputs=input_cells(frame_width,True)
    base=frame_width//4;last=base+frame_width//2
    outputs=output_cells(frame_width,base)
    assert not inputs&outputs and last<=512
    memory={}
    for parity in (0,1):
        for address in range(frame_width//2):
            for word in (0,1):
                cell=spatial_cell(parity,address,word,True)
                assert cell not in memory
                memory[cell]=('DW_source',parity,address,word)
    # Fill PW's whole row with identifiable records, not equal/zero values
    # that could conceal an overwrite of the retained DW source cache.
    for bank,address in outputs:
        assert (bank,address) not in memory
        memory[bank,address]=('PW_middle',bank,address-base)
    for parity in (0,1):
        for address in range(frame_width//2):
            for word in (0,1):
                assert memory[spatial_cell(parity,address,word,True)]==('DW_source',parity,address,word)
    for bank,address in outputs:assert memory[bank,address]==('PW_middle',bank,address-base)
    assert len(inputs)*4==frame_width//2*16 and len(outputs)*4==frame_width*16
    return dict(frame_width=frame_width,linear_base=base,linear_end_exclusive=last,
                protected_DW_bytes=len(inputs)*4,shadow_PW_bytes=len(outputs)*4,
                used_bytes=len(memory)*4,free_bytes=16384-len(memory)*4)


def main():
    source=(ROOT/'rtl/r2/c1_r2_feature_overlay_ram.sv').read_text(encoding='utf-8-sig')
    for fragment in ('spatial_rd_addr[19],spatial_rd_addr[9]',
                     'spatial_wr_addr[9]==HALF','.wr_addr(linear_wr_en[id] ? linear_wr_addr[id*9+:9] : spatial_wr_addr[8:0])',
                     'id<8','.DATA_WIDTH(32),.DEPTH(512),.ADDR_WIDTH(9)'):
        assert fragment in source,'retained physical mapping differs from model premise'
    # Both address interpretations cover exactly the same physical storage.
    universe={(bank,address) for bank in range(8) for address in range(512)}
    for repacked in (False,True):
        mapped=[spatial_cell(p,a,w,repacked) for p in (0,1) for a in range(1024) for w in (0,1)]
        assert len(mapped)==len(set(mapped))==4096 and set(mapped)==universe
    results=[proof(width) for width in range(4,641,4)]
    native=results[-1];old=input_cells(640,False)
    old_positions=[base for base in range(512-320+1) if not old&output_cells(640,base)]
    assert old_positions==[],'old native layout unexpectedly has a contiguous free PW row'
    naive_overlap=len(old&output_cells(640,160))
    assert naive_overlap==640  # 640 x32-bit locations would corrupt native DW row0.
    # Wrong base in the repacked layout must also be rejected as a collision.
    assert input_cells(640,True)&output_cells(640,159)
    # First implementation can reload the existing two command lists per
    # row, avoiding new read arbitration. This is much cheaper than per tile.
    baseline_pair_parameters=72*16
    extra_row_parameters=(480-1)*baseline_pair_parameters
    saved_roundtrip=2*640*480*16
    print('C35_ROW_PARTITION_MODEL_PASS '+json.dumps(dict(geometries=len(results),
        physical_words_per_layout=4096,old_native_free_contiguous_positions=len(old_positions),
        old_naive_overlap_words=naive_overlap,native=native,
        physical_RAM_blocks_measured=False,RTL_implemented=False,RTL_simulated=False),separators=(',',':')))
    print('C35_ROW_FUSION_TRAFFIC_CONTRACT '+json.dumps(dict(
        saved_intermediate_bytes=saved_roundtrip,extra_per_row_parameter_bytes=extra_row_parameters,
        net_bytes_saved_with_row_parameter_reload=saved_roundtrip-extra_row_parameters,
        proposed_first_implementation='repacked shared row0 plus full-row shadow; retained shared MAC and row-boundary parameter reload',
        optional_followup='co-resident DW/PW weights to remove repeated parameter commands',
        extra_large_feature_RAM_required_by_address_model=False,
        port_arbitration_and_timing_verified=False,native_fps_claim=False),separators=(',',':')))


if __name__=='__main__':main()

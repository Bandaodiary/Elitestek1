"""C35 proposed PW shadow read-base/clamping contract, not RTL evidence."""
import json
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]


def main():
    retained=(ROOT/'rtl/r2/c1_r2_pw_overlay_feeder.sv').read_text(encoding='utf-8-sig')
    assert 'even_pixel=issue_pixel+issue_pixel[0]' in retained
    assert 'odd_pixel=issue_pixel' in retained
    assert 'issue_base<=issue_base+6' in retained
    widths=transactions=active_lanes=unused_overrun=0
    examples=[]
    for width in range(4,641,4):
        base=width//4;end=base+width//2;seen=[];overrun_this_width=0
        for scalar in range(0,width*8,6):
            issue_pixel=scalar//8
            # Retained feeder reads both parity banks even when its final
            # six-lane request has fewer than six active output scalars.
            old_pixels=(issue_pixel+(issue_pixel%2),issue_pixel)
            old_addresses=tuple(base+p//2 for p in old_pixels)
            # For the unused bank only, return the last existing pixel pair.
            new_addresses=tuple(base+min(p,width-1)//2 for p in old_pixels)
            assert all(base<=a<end for a in new_addresses)
            for parity,address in enumerate(old_addresses):
                if address>=end:
                    unused_overrun+=1;overrun_this_width+=1
                    assert parity==0 and issue_pixel==width-1
                    assert not any(scalar+l<width*8 and ((scalar+l)//8)%2==parity for l in range(6))
            for lane in range(6):
                value=scalar+lane
                if value>=width*8:continue
                pixel,channel=divmod(value,8)
                assert new_addresses[pixel%2]==base+pixel//2
                seen.append((pixel,channel));active_lanes+=1
            transactions+=1
        assert seen==[(p,c) for p in range(width) for c in range(8)]
        if width in (4,12,32,640):examples.append(dict(width=width,tail_unused_bank_overruns=overrun_this_width))
        widths+=1
    assert unused_overrun>0 and examples[-1]['tail_unused_bank_overruns']==2
    print('C35_PW_SHADOW_READ_MODEL_PASS '+json.dumps(dict(geometries=widths,requests=transactions,
        checked_active_lanes=active_lanes,retained_unused_bank_overruns=unused_overrun,
        examples=examples,clamping_changes_active_lane_data=False,requires_PW_feeder_change=True,
        RTL_implemented=False,RTL_simulated=False,native_fps_claim=False),separators=(',',':')))


if __name__=='__main__':main()

"""Explicit camera cadence profiles; do not equate decimation with 30 fps.

The existing testbench uses 6666 ps core / 14286 ps camera periods. Rates
normalized to the project's nominal 150 MHz core are slightly lower than
rates measured against simulator time. Neither is a board-clock measurement.
"""
import math
from pathlib import Path
import re

ROOT=Path(__file__).resolve().parents[1]
TOP='tb_c1_r2_fused_rgb2_host_system'
PREFIX='C1_R2_FUSED_RGB2_HOST_SYSTEM_'
CORE_PERIOD_PS=6666
CAMERA_PERIOD_PS=14286
CORE_HZ=150_000_000
PROFILES={
    'legacy':dict(source_period_camera_cycles=1196052,frame_divisor=2,
                  camera_period_summary=5126552,require_capture_30fps=False),
    # Preserve the 106-tick horizontal blanking/2-pixel interface. Increase
    # vertical front blanking and admit every frame instead of every second.
    # About 30.43 fps gives ~70,837 core cycles of margin for completion jitter.
    # This is an explicit >=30 pressure profile, not measured sensor timing.
    'camera30':dict(source_period_camera_cycles=2300000,frame_divisor=1,
                    camera_period_summary=4929163,require_capture_30fps=True),
}


def profile(name):
    if name not in PROFILES:
        raise ValueError('unknown camera cadence profile')
    return dict(PROFILES[name])


def rates(period,divisor):
    if type(period) is not int or type(divisor) is not int or min(period,divisor)<=0:
        raise ValueError('positive integer period/divisor required')
    camera_to_core=CAMERA_PERIOD_PS/CORE_PERIOD_PS
    return dict(source_fps_at_nominal_core=CORE_HZ/(period*camera_to_core),
        eligible_fps_at_nominal_core=CORE_HZ/(period*camera_to_core*divisor),
        eligible_fps_from_sim_time=1e12/(period*CAMERA_PERIOD_PS*divisor),
        nominal_core_hz=CORE_HZ,core_period_ps=CORE_PERIOD_PS,camera_period_ps=CAMERA_PERIOD_PS)


def render_testbench(original,name):
    config=profile(name)
    # Refuse to produce a variant if the base source no longer matches the
    # independently checked clocking, blanking and source-cadence structure.
    anchors=('module '+TOP, 'CLOCKS_NATIVE ? 3.333 : 5.0',
             'CLOCKS_NATIVE ? 7.143 : 10.0',
             'repeat(NATIVE ? 46 : CAMERA_LINE_BLANK/2)',
             'repeat(NATIVE ? 60 : CAMERA_LINE_BLANK-CAMERA_LINE_BLANK/2)')
    if any(original.count(anchor)!=1 for anchor in anchors):
        raise ValueError('base testbench structure/clocking changed')
    replacements={
        'localparam CAMERA_PERIOD=NATIVE ? 5126552 : WIDTH*HEIGHT*25+4000;':
            f"localparam CAMERA_PERIOD=NATIVE ? {config['camera_period_summary']} : WIDTH*HEIGHT*25+4000;",
        'localparam CAMERA_FRAME_CYCLES=NATIVE ? 1196052 : CAMERA_PERIOD/4;':
            f"localparam CAMERA_FRAME_CYCLES=NATIVE ? {config['source_period_camera_cycles']} : CAMERA_PERIOD/4;",
    }
    transformed=original
    for before,after in replacements.items():
        if transformed.count(before)!=1:
            raise ValueError('base cadence declaration changed')
        transformed=transformed.replace(before,after,1)
    # Geometry is the actual native source used by the existing C36 runner.
    front=config['source_period_camera_cycles']-(1920//2+106)*(1080+2+20)
    if front<0:
        raise ValueError('camera timing has negative vertical front blanking')
    return transformed,dict(profile=name,**config,**rates(config['source_period_camera_cycles'],config['frame_divisor']),
                            native_vertical_front_cycles=front,production_RTL_changed=False,RTL_compiled=False)


def event_rows(text,kind):
    result=[]
    for body in re.findall(r'^'+re.escape(PREFIX+kind)+r' ([^\r\n]*)$',text,re.M):
        result.append({key:int(value) for key,value in re.findall(r'(\w+)=(-?\d+)',body)})
    return result


def single(text,kind):
    rows=event_rows(text,kind)
    if len(rows)!=1:
        raise ValueError('missing/duplicate camera evidence: '+kind)
    return rows[0]


def assess(text,name='legacy'):
    config=profile(name)
    camera=single(text,'CAMERA');rgb2=single(text,'RGB2');passed=single(text,'PASS')
    sofs=event_rows(text,'SOURCE_SOF');captures=event_rows(text,'CAPTURE')
    period=config['source_period_camera_cycles'];divisor=config['frame_divisor']
    if (rgb2['frame_divisor']!=divisor or camera['source_sof_cycles']!=period or
        rgb2['source_period_camera_cycles']!=period or passed['camera_period']!=config['camera_period_summary']):
        raise ValueError('actual camera cadence differs from requested profile')
    if (len(sofs)!=camera['frames'] or len(captures)!=passed['captures'] or
        len(sofs)<2 or len(captures)<2 or passed['native_timing']!=1):
        raise ValueError('incomplete native source/capture observations')
    if [s['tag'] for s in sofs]!=list(range(len(sofs))):
        raise ValueError('missing/duplicate source tags')
    if [c['tag'] for c in captures]!=[s['tag'] for s in sofs if s['tag']%divisor==0]:
        raise ValueError('eligible frames were dropped or repeated')
    for current,following in zip(sofs,sofs[1:]):
        if following['camera_cycle']-current['camera_cycle']!=period:
            raise ValueError('camera source changed its cadence')
    origin=sofs[0]
    for sof in sofs:
        expected=(sof['camera_cycle']-origin['camera_cycle'])*CAMERA_PERIOD_PS/CORE_PERIOD_PS
        if abs(sof['core_cycle']-origin['core_cycle']-expected)>1:
            raise ValueError('actual source/core clock mapping differs')
    intervals=[b['cycle']-a['cycle'] for a,b in zip(captures,captures[1:])]
    if min(intervals)<=0:
        raise ValueError('nonmonotonic completed captures')
    measured=rates(period,divisor)
    worst=max(intervals)
    return dict(profile=name,**config,**measured,
        captures=len(captures),source_frames=len(sofs),capture_completion_intervals=intervals,
        min_observed_capture_fps_at_nominal_core=CORE_HZ/worst,
        target_capture_fps=30,capture_interval_budget_core_cycles=5_000_000,
        all_eligible_source_frames_captured=True,
        capture_30fps_met_for_observed_intervals=(measured['eligible_fps_at_nominal_core']>=30 and worst<=5_000_000),
        board_frequency_measured=False,source_evidence_scope='actual retained source SOFs and capture completions',
        CNN_fps_not_redefined=True)


def self_test():
    original=(ROOT/'sim'/f'{TOP}.sv').read_text(encoding='utf-8-sig')
    unchanged,old=render_testbench(original,'legacy')
    assert unchanged==original and old['eligible_fps_at_nominal_core']<30
    changed,new=render_testbench(original,'camera30')
    assert new['eligible_fps_at_nominal_core']>=30 and new['frame_divisor']==1
    assert new['native_vertical_front_cycles']>old['native_vertical_front_cycles']>=0
    period=new['source_period_camera_cycles'];summary=new['camera_period_summary']
    assert summary==math.ceil(period*CAMERA_PERIOD_PS/CORE_PERIOD_PS)
    assert 5_000_000-summary>70_000
    recovered=changed.replace(f'CAMERA_PERIOD=NATIVE ? {summary}','CAMERA_PERIOD=NATIVE ? 5126552',1)
    recovered=recovered.replace(f'CAMERA_FRAME_CYCLES=NATIVE ? {period}','CAMERA_FRAME_CYCLES=NATIVE ? 1196052',1)
    assert recovered==original
    for altered in (original.replace('7.143','7.100'),original.replace('1196052','1196053')):
        try:
            render_testbench(altered,'camera30')
        except ValueError:
            pass
        else:
            raise AssertionError('changed base clock/cadence accepted')
    # Synthetic counter tests exercise exact clock mapping and dropped-source
    # rejection. They are explicitly not a real new-profile RTL execution.
    lines=[PREFIX+f'CAMERA frames=4 source_sof_cycles={period}',
           PREFIX+f'RGB2 frame_divisor=1 source_period_camera_cycles={period}',
           PREFIX+f'PASS native_timing=1 captures=4 camera_period={summary}']
    for index in range(4):
        core=round(index*period*CAMERA_PERIOD_PS/CORE_PERIOD_PS)
        lines.append(PREFIX+f'SOURCE_SOF tag={index} camera_cycle={index*period} core_cycle={core}')
        lines.append(PREFIX+f'CAPTURE tag={index} words=76800 cycle={core+1000}')
    synthetic='\n'.join(lines)
    assert assess(synthetic,'camera30')['capture_30fps_met_for_observed_intervals']
    for damaged in (synthetic.replace('frame_divisor=1','frame_divisor=2'),
                    synthetic.replace('CAPTURE tag=2','OMITTED tag=2'),
                    synthetic.replace(f'camera_cycle={period}',f'camera_cycle={period+1}')):
        try:
            assess(damaged,'camera30')
        except (ValueError,KeyError):
            pass
        else:
            raise AssertionError('incorrect synthetic camera trace accepted')
    print('C36_CAMERA_CADENCE_CONTRACT_PASS legacy_below_30=1 candidate_at_least_30=1 '
          'only_two_TB_constants_changed=1 changed_base_rejected=2 trace_negative_controls=3 new_profile_RTL_run=0')


if __name__=='__main__':
    self_test()

"""100 MHz host timing fixture. Actual Sapphire execution is a separate gate."""
import json
from pathlib import Path
from r2_camera_cadence_contract import ROOT, TOP, render_testbench

CORE_HZ = 100_000_000
CORE_PS = 10_000
CAMERA_PS = 14_286
SOURCE_TICKS = 2_300_000


def replace_once(text, old, new):
    if text.count(old) != 1:
        raise ValueError('timing fixture anchor changed: ' + old)
    return text.replace(old, new, 1)


def fixture(original):
    text, _ = render_testbench(original, 'camera30')
    for old, new in (
        ('CLOCKS_NATIVE ? 3.333 : 5.0', '5.0'),
        ('localparam CAMERA_PERIOD=NATIVE ? 4929163 : WIDTH*HEIGHT*25+4000;',
         'localparam CAMERA_PERIOD=NATIVE ? 3285780 : WIDTH*HEIGHT*25+4000;'),
        ('phase=phase+(NATIVE ? 99 : 1);', 'phase=phase+(NATIVE ? 297 : 1);'),
        ('phase>=(NATIVE ? 200 : 16)', 'phase>=(NATIVE ? 400 : 16)'),
        ('phase=phase-(NATIVE ? 200 : 16);', 'phase=phase-(NATIVE ? 400 : 16);'),
        ('// Native 720p60: 74.25MHz pixel events sampled in a 150MHz core domain,',
         '// C40 720p60: 74.25MHz pixel events sampled in a 100MHz core domain,'),
        ('// exact 99/200 ratio,', '// exact 297/400 ratio,'),
    ):
        text = replace_once(text, old, new)
    declarations = '''
    realtime c40_previous_core=0, c40_previous_camera=0;
    integer c40_core_edges=0,c40_camera_edges=0,c40_pixel_events=0;
    integer c40_display_ticks=0,c40_display_phase=0;
'''
    text = replace_once(text, 'module '+TOP+';', 'module '+TOP+';'+declarations)
    monitor = '''
    // Measure clocks and display requests in the simulator, not from filenames.
    always @(posedge clk) begin
        if(c40_core_edges>0 && $realtime-c40_previous_core != 10.0)
            $fatal(1,"C40 core clock is not 100MHz");
        c40_previous_core=$realtime;c40_core_edges=c40_core_edges+1;
    end
    always @(posedge cam_clk) begin
        if(c40_camera_edges>0 && CLOCKS_NATIVE &&
           (($realtime-c40_previous_camera < 14.2855) ||
            ($realtime-c40_previous_camera > 14.2865)))
            $fatal(1,"C40 camera clock changed");
        c40_previous_camera=$realtime;c40_camera_edges=c40_camera_edges+1;
    end
    // Delayed sampling avoids races with the existing negedge video driver.
    always @(negedge clk) begin
        #0.001;
        if(rst || !video_run) begin c40_display_ticks=0;c40_display_phase=0;end
        else if(NATIVE) begin
            c40_display_ticks=c40_display_ticks+1;
            c40_display_phase=c40_display_phase+297;
            if(c40_display_phase>=400)begin
                c40_display_phase=c40_display_phase-400;
                c40_pixel_events=c40_pixel_events+1;
            end
            if(phase!==c40_display_phase)$fatal(1,"C40 display phase mismatch");
        end
    end
'''
    text = replace_once(text, '\nendmodule', monitor + '\nendmodule')
    text = replace_once(text, '        $finish;', '''        $display("C40_CLOCK_PASS core_hz=100000000 core_edges=%0d camera_edges=%0d pixel_events=%0d display_num=297 display_den=400 actual_CPU_IP=0",c40_core_edges,c40_camera_edges,c40_pixel_events);
        $finish;''')
    return text


def throughput(intervals):
    if len(intervals) != 5 or any(type(x) is not int or x <= 0 for x in intervals):
        raise ValueError('six completed frames and five positive integer intervals required')
    worst = max(intervals)
    return dict(core_hz=CORE_HZ, worst_cycles=worst, fps=CORE_HZ/worst,
                target_met=worst*15 <= CORE_HZ, budget_cycles=CORE_HZ//15,
                margin_cycles=CORE_HZ//15-worst, actual_CPU_IP=False,
                official_joint_throughput_verified=False)


def self_test():
    original = (ROOT/'sim'/f'{TOP}.sv').read_text(encoding='utf-8-sig')
    changed = fixture(original)
    assert '3.333' not in changed
    assert 'NATIVE ? 297 : 1' in changed and 'NATIVE ? 400 : 16' in changed
    assert 'CLOCKS_NATIVE ? 7.143 : 10.0' in changed
    assert throughput([6_666_666]*5)['target_met']
    assert not throughput([6_666_667]+[1]*4)['target_met']
    negatives = 0
    for bad in ([1]*4, [1]*6, [1]*4+[0], [1]*4+[True], [1]*4+[1.0]):
        try: throughput(bad)
        except ValueError: negatives += 1
        else: raise AssertionError('invalid interval accepted')
    # Independent cadence arithmetic: 297 events/400 clocks gives 74.25 MHz.
    phase=events=0
    for _ in range(400):
        phase += 297
        if phase >= 400: phase -= 400; events += 1
    assert events == 297 and phase == 0 and CORE_HZ*events/400 == 74_250_000
    print('C40_CONTRACT_PASS '+json.dumps(dict(invalid_intervals_rejected=negatives,
        exact_15fps_boundary_checked=True, display_hz=74_250_000,
        camera_source_fps=1e12/(SOURCE_TICKS*CAMERA_PS), RTL_simulated=False)))


if __name__ == '__main__':
    self_test()

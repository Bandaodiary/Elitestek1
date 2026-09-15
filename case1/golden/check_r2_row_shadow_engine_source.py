"""C35 source closure/passthrough audit only; NOT an HDL compiler or simulator."""
import json
from pathlib import Path
import re

ROOT=Path(__file__).resolve().parents[1]


def passthrough(old,new,child_old,child_new):
    source=(ROOT/'rtl/r2'/f'{old}.sv').read_text(encoding='utf-8-sig')
    actual=(ROOT/'rtl/r2'/f'{new}.sv').read_text(encoding='utf-8-sig')
    expected='// C35 independent partition-control passthrough; retained scheduling unchanged.\n'+source
    expected=expected.replace(f'module {old} (',f'module {new} (\n    input wire partition_en,\n'
        '    input wire [8:0] partition_base,\n    input wire [9:0] partition_end,')
    instance='u_overlay' if old.endswith('window_store_packed') else 'u_store'
    a=f'{child_old} {instance} ('
    assert expected.count(a)==1
    expected=expected.replace(a,f'{child_new} {instance} (\n'
        '        .partition_en(partition_en),.partition_base(partition_base),.partition_end(partition_end),')
    if old.endswith('window_store_packed'):
        previous='        if((linear_rd_en || |linear_wr_en) && (reserved_count!=0 || second_q || pending_valid || push || bulk_en))\n'
        previous+='            $fatal(1,"overlay window still owns shared feature storage");'
        updated='''        // PW reads still require a full spatial drain. Only a bounded
        // shadow WRITE may overlap active DW windows, using the SDP write
        // ports in the disjoint upper partition. The leaf RAM checks each
        // read/write address and retains its physical port collision checks.
        if(linear_rd_en && (reserved_count!=0 || second_q || pending_valid || push || bulk_en))
            $fatal(1,"partition window linear reader before spatial drain");
        if(|linear_wr_en && ((!partition_en && (reserved_count!=0 || second_q || pending_valid || push || bulk_en)) ||
                              (partition_en && (bulk_en || write_en))))
            $fatal(1,"partition window illegal linear write ownership");'''
        assert expected.count(previous)==1
        expected=expected.replace(previous,updated)
    assert actual==expected,f'undeclared partition wrapper change: {new}'


def audited_sources():
    passthrough('c1_r2_overlay_window_store_packed','c1_r2_partitioned_window_store',
                'c1_r2_feature_overlay_ram','c1_r2_partitioned_feature_ram')
    passthrough('c1_r2_spatial_packed_feeder','c1_r2_spatial_partitioned_feeder',
                'c1_r2_overlay_window_store_packed','c1_r2_partitioned_window_store')
    root='c1_r2_cnn_row_shadow_engine';todo=[root];seen={};paths=[]
    while todo:
        module=todo.pop()
        if module in seen:continue
        files=[ROOT/'rtl'/directory/f'{module}.sv' for directory in ('r2','common','cnn')]
        files=[file for file in files if file.is_file()]
        assert len(files)==1,f'missing/ambiguous source: {module}'
        paths.append(files[0])
        text=files[0].read_text(encoding='utf-8-sig')
        assert re.search(r'\bmodule\s+'+module+r'\b',text),module
        text=re.sub(r'/\*.*?\*/|//[^\n]*','',text,flags=re.S)
        children=re.findall(r'^\s*(c1_\w+)\s*(?:#\s*\(|\w+\s*\()',text,flags=re.M)
        seen[module]=children;todo.extend(children)
    engine=(ROOT/'rtl/r2'/f'{root}.sv').read_text(encoding='utf-8-sig')
    assert engine.count('c1_r2_compute6_compact u_compute')==1
    assert engine.count('c1_r2_weight_store6 #(.PACKED(1)) u_weights')==1
    assert '.out_ready(compute_sink_ready && busy)' in engine
    assert '.in_valid(busy && compute_valid && capture_q)' in engine
    assert '.start_valid(start_fire && start_shadow_capture)' in engine
    assert 'assign out_valid=busy && compute_valid && !capture_q' in engine
    assert '.linear_wr_en(linear_wr_en|shadow_wr_en)' in engine
    assert 'shadow_consumed_q<=!start_shadow_capture' in engine
    assert 'c1_r2_cnn_capacity_engine' not in engine
    print('C35_ROW_SHADOW_ENGINE_SOURCE_PASS '+json.dumps(dict(source_closure=len(seen),
        declared_partition_wrappers=2,partition_write_overlap_guard_changed=1,
        shared_compute_instances=1,shared_parameter_store_instances=1,
        RTL_compiled=False,RTL_simulated=False,graph_scheduler_connected=False,physical_RAM_measured=False,
        native_fps_claim=False),separators=(',',':')))
    return paths


if __name__=='__main__':audited_sources()

"""Bounded, read-only vendor port/clock audit. No encrypted payload decoding."""
import itertools
import json
import re
from pathlib import Path
import xml.etree.ElementTree as ET
import check_r2_rgb2_host_evidence as c31

VENDOR=Path('D:/contest/Ti60F225_DemoBoard_v4/08_ti60f225_soc_demo/09_Ti60F225_co_debug_demo')


def head(path,lines):
    with path.open(encoding='utf-8-sig',errors='replace') as f:
        return ''.join(itertools.islice(f,lines))


def width(text,port,direction):
    m=re.search(rf'\b{direction}\s+(?:wire\s+)?(?:\[(\d+):0\]\s+)?{re.escape(port)}\s*[,\)]',text)
    assert m,port
    return int(m[1])+1 if m[1] else 1


def main():
    project=VENDOR/'par/ddr_demo_ti60'
    x=ET.parse(project/'ddr_demo_ti60.xml').getroot()
    ips=[e for e in x.iter() if e.tag.rsplit('}',1)[-1]=='ip' and e.attrib.get('instance_name')=='soc']
    assert len(ips)==1 and ips[0].attrib['path']=='ip/soc/settings.json'
    assert any(e.attrib.get('name')=='soc.v' for e in ips[0])
    soc=head(project/'ip/soc/soc.v',240)
    top=head(VENDOR/'rtl/ddr3_example_top.v',510)
    params=head(VENDOR/'rtl/ddr3_controller/ddr3_parameter.vh',95)
    sdc=head(project/'sdc/ddr3.sdc',100)
    axi_header=head(VENDOR/'rtl/ddr3_controller/axi4_bus_ctl/axi4_bus_ctl.v',109)
    ports=dict(ddr_data=width(soc,'io_ddrA_w_payload_data','output'),
               ddr_strobe=width(soc,'io_ddrA_w_payload_strb','output'),
               ddr_id=width(soc,'io_ddrA_aw_payload_id','output'),
               ddr_address=width(soc,'io_ddrA_aw_payload_addr','output'),
               external_ingress_data=width(soc,'io_ddrMasters_0_w_payload_data','input'),
               external_ingress_id=width(soc,'io_ddrMasters_0_aw_payload_id','input'),
               peripheral_axi_data=width(soc,'axiA_wdata','output'),
               peripheral_axi_id=width(soc,'axiA_awid','output'),
               apb_address=width(soc,'io_apbSlave_0_PADDR','output'),
               interrupt=width(soc,'userInterruptA','input'))
    assert ports==dict(ddr_data=128,ddr_strobe=16,ddr_id=8,ddr_address=32,
                       external_ingress_data=32,external_ingress_id=4,peripheral_axi_data=32,
                       peripheral_axi_id=8,apb_address=16,interrupt=1)
    defines={k:int(v) for k,v in re.findall(r'`define\s+(AXI_DATA_WIDTH|AXI_ID_WIDTH|AXI_ADDR_WIDTH|ASYN_AXI_CLK|CK_RATIO)\s+(\d+)',params)}
    assert defines==dict(AXI_ID_WIDTH=4,AXI_ADDR_WIDTH=28,AXI_DATA_WIDTH=128,CK_RATIO=4,ASYN_AXI_CLK=0)
    assert re.search(r'else\s+begin\s+assign\s+user_clk\s*=\s*core_clk',top)
    assert re.search(r'create_clock\s+-period\s+10\.00\s+core_clk',sdc)
    assert re.search(r'\.io_memoryClk\s*\(user_clk\s*\)',top)
    assert re.search(r'\.io_ddrA_b_payload_resp\s*\(\s*\)',top),'legacy B response wiring differs'
    assert 'io_ddrMasters_0' not in top,'external ingress is now connected; re-audit actual clock'
    assert '`pragma protect begin_protected' in axi_header
    bfm=head(c31.ROOT/'sim/c1_r2_axi_memory_bfm.sv',160)
    assert 'm_axi_arsize!=4' in bfm and 'm_axi_awsize!=4' in bfm
    assert 'm_axi_araddr[3:0]!=0' in bfm and 'm_axi_awaddr[3:0]!=0' in bfm
    # Reuse actual observed complete per-job traffic, not an inferred FPS.
    log=c31.read(c31.ROOT/'logs/r2_rgb2_host_xsim_runs/c31_rgb2_native_sixframe_20260914_c/xsim.tail.log')
    frame=[r for r in c31.rows(log,'FRAME',c31.P) if r['tag']==20][0]
    cnn_read=frame['read_beats']*16*15
    scan_read=2*640*480*4*60
    data=dict(soc_ports=ports,controller_defines=defines,user_clock_nominal_mhz=100,
        external_ingress_connected_in_example=False,controller_implementation_encrypted=True,
        actual_AWREADY_policy='not_proven',legacy_cpu_BRESP_unconnected=True,
        current_full_host_BFM_requires_16byte_aligned_fullwidth=True,
        actual_Sapphire_narrow_transaction_behavior_proven=False,
        read_bandwidth_example=dict(assumed_ingress_clock_mhz=100,assumed_CNN_fps=15,
            assumed_two_pane_display_hz=60,ingress_32bit_peak_bytes_per_second=400000000,
            CNN_read_bytes_per_second=cnn_read,scanout_read_bytes_per_second=scan_read,
            combined_read_bytes_per_second=cnn_read+scan_read),
        board_validation=False,whole_system_compatibility_proven=False)
    print('C32_OFFICIAL_DDR_STATIC_CONTRACT '+json.dumps(data,separators=(',',':')))
    print('C32_OFFICIAL_DDR_STATIC_PASS bounded_header_reads=1 active_soc_IP_resolved=1 encrypted_body_read=0 no_vendor_edits=1 no_AW_policy_inference=1 no_board_claim=1')


if __name__=='__main__':main()

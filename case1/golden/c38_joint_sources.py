"""C38 resource-only joint Sapphire/C37/vendor-DDR closure.

Read public vendor headers only. Emit edits as an apply_patch document; never
rewrite vendor or C37 files. No simulation/board compatibility claim is implied.
"""
import argparse
import ast
import itertools
import json
import re
from pathlib import Path
import xml.etree.ElementTree as ET
from c37_sources import ROOT, sources

VENDOR = Path('D:/contest/Ti60F225_DemoBoard_v4/08_ti60f225_soc_demo/09_Ti60F225_co_debug_demo')
PROJECT = VENDOR/'par/ddr_demo_ti60/ddr_demo_ti60.xml'
SOC = PROJECT.parent/'ip/soc/soc.v'
DDR = VENDOR/'rtl/ddr3_controller/ddr3_top.v'
HOST = ROOT/'rtl/r2/c1_r2_fused_rgb2_host_system.sv'
NAME = 'c1_ti60_c38_soc_ddr_resource'
NAMESPACE = 'http://www.efinixinc.com/enf_proj'


def head(path, count):
    with path.open(encoding='utf-8-sig') as stream:
        return ''.join(itertools.islice(stream, count))


def number(expression, constants):
    for name, value in constants.items():
        expression = re.sub(r'\b'+name+r'\b', str(value), expression)
    node = ast.parse(expression, mode='eval')
    allowed = (ast.Expression, ast.Constant, ast.BinOp, ast.Add, ast.Sub,
               ast.Mult, ast.Div, ast.FloorDiv, ast.Load)
    if any(not isinstance(item, allowed) for item in ast.walk(node)):
        raise ValueError('unsupported public width: '+expression)
    value = eval(compile(node, '<width>', 'eval'), {'__builtins__': {}})
    if int(value) != value:
        raise ValueError('noninteger public width')
    return int(value)


def ports(path, module, lines, constants):
    text = re.sub(r'/\*.*?\*/|//[^\n]*', '', head(path, lines), flags=re.S)
    match = re.search(r'\bmodule\s+'+module+r'\s*(?:#\s*\(.*?\)\s*)?\((.*?)\)\s*;', text, re.S)
    if not match:
        raise ValueError('public header not found: '+module)
    result, direction, width = {}, None, 1
    for token in match[1].split(','):
        token = token.strip()
        declaration = re.fullmatch(r'(input|output|inout)\s+(?:(?:wire|logic|reg)\s+)?(?:\[([^:]+):([^\]]+)\]\s*)?(\w+)', token)
        if declaration:
            direction = declaration[1]
            width = number(declaration[2], constants)-number(declaration[3], constants)+1 if declaration[2] else 1
            name = declaration[4]
        elif re.fullmatch(r'\w+', token) and direction:
            name = token
        else:
            raise ValueError('unsupported public port: '+token)
        if name in result or width <= 0:
            raise ValueError('duplicate/invalid port')
        result[name] = (direction, width)
    return result


def build():
    defines=dict((name,int(value)) for name,value in re.findall(
        r'^`define\s+(\w+)\s+(\d+)\s*$',head(DDR.parent/'ddr3_parameter.vh',95),re.M))
    expected=dict(AXI_DATA_WIDTH=128,AXI_ID_WIDTH=4,AXI_ADDR_WIDTH=28,
        ASYN_AXI_CLK=0,CK_RATIO=4,ROW_WIDTH=14,DQ_WIDTH=16,DQS_WIDTH=2)
    if any(defines.get(name)!=value for name,value in expected.items()):
        raise ValueError('official DDR geometry/clock parameters changed; re-audit integration')
    hp = ports(HOST, 'c1_r2_fused_rgb2_host_system', 116, {'CPU_ID_WIDTH':8})
    sp = ports(SOC, 'soc', 218, {})
    dp = ports(DDR, 'ddr3_top', 179, dict(CKE_WIDTH=1,ROW_WIDTH=14,BANK_WIDTH=3,
        CS_WIDTH=1,RANK_RATIO=1,DQS_WIDTH=2,DQ_WIDTH=16,DM_WIDTH=2,ODT_WIDTH=1,
        AXI_ID_WIDTH=4,AXI_ADDR_WIDTH=28,AXI_DATA_WIDTH=128))
    assert sp['io_ddrA_w_payload_data'] == ('output',128)
    assert sp['io_ddrA_aw_payload_id'] == ('output',8)
    assert dp['s_axi_awid'] == ('input',4)
    external = {'core_clk':('input',1),'reset_n':('input',1)}
    wires = {'host_rst':1,'cal_ready':1,'ddr_cal_done':1}
    links = {'host':{},'soc':{},'ddr':{}}
    assigns = []
    def expose(target, port, name, declaration):
        if name in external and external[name] != declaration:
            raise ValueError('conflicting external port '+name)
        external[name] = declaration
        links[target][port] = name
    def net(target, port, name, width):
        if name in wires and wires[name] != width:
            raise ValueError('conflicting net '+name)
        wires[name] = width
        links[target][port] = name
    for port, declaration in hp.items():
        direction, width = declaration
        if port in ('clk','rst','platform_ready'):
            links['host'][port] = dict(clk='core_clk',rst='host_rst',platform_ready='cal_ready')[port]
        elif port == 'cam_rst':
            links['host'][port] = 'cam_reset_pipe[1]'
        elif port.startswith(('cpu_','m_axi_')) or port in ('psel','penable','pwrite','paddr','pwdata','prdata','pready','pslverr','irq'):
            net('host',port,port,width)
        else:
            expose('host',port,port,declaration)
    apb = dict(PADDR='paddr',PSEL='psel',PENABLE='penable',PWRITE='pwrite',
               PWDATA='pwdata',PRDATA='prdata',PREADY='pready',PSLVERROR='pslverr')
    ignored_sidebands = []
    for port, declaration in sp.items():
        direction, width = declaration
        if port in ('io_systemClk','io_memoryClk'):
            links['soc'][port] = 'core_clk'
        elif port == 'io_asyncReset':
            links['soc'][port] = '!reset_n'
        elif port == 'userInterruptA':
            links['soc'][port] = 'irq'
        elif port.startswith('io_apbSlave_0_'):
            net('soc',port,apb[port.removeprefix('io_apbSlave_0_')],width)
        elif port.startswith('io_ddrA_'):
            suffix = port.removeprefix('io_ddrA_').replace('_payload_','').replace('_','')
            name = 'cpu_'+suffix
            if name not in wires:
                if direction != 'output' or not suffix.endswith(('cache','prot','qos')):
                    raise ValueError('unmapped CPU DDR signal '+port)
                ignored_sidebands.append(port)
                links['soc'][port] = ''
            elif suffix in ('arvalid','awvalid','wvalid'):
                net('soc',port,'soc_'+suffix,width)
                assigns.append(f'assign {name}=soc_{suffix} && cal_ready;')
            elif suffix in ('arready','awready','wready'):
                links['soc'][port] = name+' && cal_ready'
            else:
                net('soc',port,name,width)
        elif port.startswith('io_ddrMasters_0_'):
            links['soc'][port] = 'core_clk' if port.endswith('_clk') else (
                ("1'b1" if port.endswith(('_r_ready','_b_ready')) else "'0") if direction=='input' else '')
        else:
            expose('soc',port,'soc_'+port,declaration)
    for port, declaration in dp.items():
        direction, width = declaration
        if port in ('axi_clk','core_clk'):
            links['ddr'][port] = 'core_clk'
        elif port == 'rstn':
            links['ddr'][port] = 'reset_n'
        elif port == 'cal_done':
            links['ddr'][port] = 'ddr_cal_done'
        elif port.startswith('s_axi_'):
            name = 'm_axi_'+port.removeprefix('s_axi_')
            if port.endswith(('araddr','awaddr')):
                assert width == 28 and wires[name] == 32
                links['ddr'][port] = name+'[27:0]'
            else:
                if wires[name] != width:
                    raise ValueError('DDR width mismatch '+port)
                links['ddr'][port] = name
        elif port in ('app_sr_req','app_ref_req','app_zq_req'):
            links['ddr'][port] = "1'b0"
        else:
            expose('ddr',port,'phy_'+port,declaration)
    # Fault and calibration outputs must remain observable in resource mapping.
    for name in ('cpu_adapter_busy','cpu_adapter_fault'):
        external[name] = ('output',wires.pop(name))
    external['calibrated'] = ('output',1)
    assigns.append('assign calibrated=cal_ready;')
    def declaration(direction,width,name):
        return direction+' wire '+(f'[{width-1}:0] ' if width>1 else '')+name
    text = '// C38 resource-only joint wrapper. Generated from public port headers.\n'
    text += '// NOT a board top: no periphery/pin/PLL assignment, CSI or HDMI PHY.\n'
    text += '// CPU path: normal noncoherent aligned INCR DDR only; see C13 contract.\n'
    text += '// 28-bit physical DDR addressing relies on C37 fixed arena and CPU range checks.\n'
    text += '`timescale 1ns/1ps\n`default_nettype none\n'
    text += 'module '+NAME+' (\n'+',\n'.join('    '+declaration(d,w,n) for n,(d,w) in external.items())+'\n);\n'
    text += '\n'.join('    '+declaration('',w,n).strip()+';' for n,w in wires.items())+'\n'
    text += '''    (* async_reg="true" *) reg [1:0] reset_pipe,cam_reset_pipe,cal_pipe;
    always @(posedge core_clk or negedge reset_n)
        if(!reset_n) begin reset_pipe<=2'b11;cal_pipe<=0;end
        else begin reset_pipe<={reset_pipe[0],1'b0};cal_pipe<={cal_pipe[0],ddr_cal_done};end
    always @(posedge cam_clk or negedge reset_n)
        if(!reset_n) cam_reset_pipe<=2'b11;
        else cam_reset_pipe<={cam_reset_pipe[0],1'b0};
    assign host_rst=reset_pipe[1];
    assign cal_ready=cal_pipe[1] && !host_rst;
'''
    text += '\n'.join('    '+line for line in assigns)+'\n'
    for key,module,params in (('soc','soc',''),('host','c1_r2_fused_rgb2_host_system',' #(.FRAME_DIVISOR(1))'),('ddr','ddr3_top','')):
        text += '    '+module+params+' u_'+key+' (\n'+',\n'.join(f'        .{p}({n})' for p,n in links[key].items())+'\n    );\n'
    text += '''`ifndef SYNTHESIS
    always @(posedge core_clk) if(!host_rst) begin
        if((m_axi_arvalid && m_axi_araddr[31:28]!=0) ||
           (m_axi_awvalid && m_axi_awaddr[31:28]!=0))
            $fatal(1,"C38 address exceeds physical 256MiB DDR");
    end
`endif
endmodule
`default_nettype wire
'''
    root = ET.parse(ROOT/'efinity/c1_ti60_c37_resource24.xml').getroot()
    root.attrib.update(name=NAME,description='C38 resource-only real Sapphire + C37 + vendor DDR; no board/PHY signoff')
    tag = lambda name: '{'+NAMESPACE+'}'+name
    info = root.find(tag('design_info'))
    for entry in list(info):
        if entry.tag in (tag('design_file'),tag('top_module'),tag('top_vhdl_arch')):
            info.remove(entry)
    ET.SubElement(info,tag('top_module'),name=NAME)
    closure = list(sources())
    for entry in ET.parse(PROJECT).getroot().iter():
        if entry.tag != tag('design_file'):
            continue
        path = (PROJECT.parent/entry.attrib['name']).resolve()
        if path.suffix=='.v' and ('ddr3_controller' in path.parts or path.name=='simple_dual_port_ram.v'):
            closure.append(path)
    closure += [SOC,ROOT/'efinity'/f'{NAME}.sv']
    if len(set(closure)) != len(closure):
        raise ValueError('duplicate source')
    for path in closure:
        ET.SubElement(info,tag('design_file'),name=path.as_posix(),version='default',library='default')
    ET.SubElement(info,tag('top_vhdl_arch'),name='')
    root.find(tag('constraint_info')).find(tag('sdc_file')).set('name',NAME+'.sdc')
    ET.SubElement(root.find(tag('synthesis')),tag('param'),name='include',
        value=(VENDOR/'rtl/ddr3_controller').as_posix(),value_type='e_string')
    ET.register_namespace('efx',NAMESPACE)
    ET.indent(root,space='    ')
    xml = '<?xml version="1.0" encoding="UTF-8"?>\n'+ET.tostring(root,encoding='unicode')+'\n'
    sdc = '# Resource-only clock targets; NOT a physical clock/CDC signoff.\n'
    for name,period in [('core_clk',10),('cam_clk',14.286),('phy_sdram_clk',2.5),('phy_rx_cal_clk',2.5),('phy_tx_cal_clk',2.5),('phy_tx_cal_clk_90edge',2.5)]:
        sdc += f'create_clock -name {name} -period {period} [get_ports {name}]\n'
    contract = dict(role='resource-only joint logic',host_ports=len(hp),soc_ports=len(sp),ddr_ports=len(dp),
        sources=len(closure),cpu_data_bits=128,cpu_id_bits=8,ddr_data_bits=128,ddr_id_bits=4,
        ddr_address_bits=28,apb_address_bits=16,frame_divisor=1,core_clock_mhz=100,
        ignored_normal_DDR_sidebands=ignored_sidebands,external_32bit_ingress_disabled=True,
        actual_Sapphire_simulated=False,actual_DDR_simulated=False,board_fit_proven=False,
        calibration_gates_cpu_requests=True,DDR_reset_independent_of_calibration=True,
        source_paths=[p.as_posix() for p in closure])
    return {f'efinity/{NAME}.sv':text,f'efinity/{NAME}.xml':xml,f'efinity/{NAME}.sdc':sdc,
            'review/C38_JOINT_SOURCE_CONTRACT.json':json.dumps(contract,indent=2)+'\n'}


def same_artifact(relative, actual, expected):
    # efx_run removes the optional XML declaration in ProjectInPlace mode.
    # Compare every XML element/attribute, not formatting of that declaration.
    if relative.endswith('.xml'):
        return ET.tostring(ET.fromstring(actual)) == ET.tostring(ET.fromstring(expected))
    return actual == expected


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--emit-patch',action='store_true')
    args=parser.parse_args()
    files=build()
    if args.emit_patch:
        print('*** Begin Patch')
        for relative,text in files.items():
            if (ROOT/relative).exists():
                raise ValueError('refusing to overwrite '+relative)
            print('*** Add File: case1/'+relative)
            print('\n'.join('+'+line for line in text.splitlines()))
        print('*** End Patch')
    else:
        for relative,text in files.items():
            if not same_artifact(relative,(ROOT/relative).read_text(encoding='utf-8-sig'),text):
                raise ValueError('generated closure differs: '+relative)
        print('C38_SOURCE_REPRODUCTION_PASS files=4 vendor_modified=0 resource_measurement=0 board_fit_proven=0')


if __name__=='__main__':
    main()

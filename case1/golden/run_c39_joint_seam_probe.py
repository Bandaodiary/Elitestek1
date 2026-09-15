"""Exercise C39 wiring with explicit behavioral vendor doubles, NOT CPU/PHY simulation."""
import ctypes
import subprocess
import tempfile
from pathlib import Path
import argparse
import json
from c38_joint_sources import ROOT, DDR, HOST, ports as original_ports, same_artifact
from c37_sources import sources as retained_sources
from c39_candidate_sources import sources as candidate_sources
from c39_joint_projects import artifacts, host_sources
from c39_sapphire_port_audit import public_ports

parser=argparse.ArgumentParser()
parser.add_argument('directory',type=Path)
parser.add_argument('--host',choices=('c37','c39','direct','native','onehot'),default='c39')
args=parser.parse_args()
directory=args.directory.resolve()
report=json.loads((directory/'validated_config.json').read_text(encoding='utf-8'))
profile=report['profile']
CPU_MODULE='c39_soc_'+profile
SOC=directory/'ip'/CPU_MODULE/(CPU_MODULE+'.v')
NAME='c1_ti60_c39_joint_'+profile+'_'+args.host
sources=host_sources(args.host)
def build():return artifacts(directory,args.host)
def ports(path,module,count,constants):
    return public_ports(path,CPU_MODULE) if path==SOC else original_ports(path,module,count,constants)


def declaration(direction, width, name):
    return direction+' '+('reg ' if direction=='output' else 'wire ')+(f'[{width-1}:0] ' if width>1 else '')+name


def main():
    from run_c37_leaf_probe import budget
    from c39_seam_admission import check
    budget()
    check()
    execute()


def execute():
    for relative,expected in build().items():
        if not same_artifact(relative,(ROOT/relative).read_text(encoding='utf-8-sig'),expected):
            raise ValueError('source closure differs: '+relative)
    soc=ports(SOC,'soc',218,{})
    ddr=ports(DDR,'ddr3_top',179,dict(CKE_WIDTH=1,ROW_WIDTH=14,BANK_WIDTH=3,
        CS_WIDTH=1,RANK_RATIO=1,DQS_WIDTH=2,DQ_WIDTH=16,DM_WIDTH=2,ODT_WIDTH=1,
        AXI_ID_WIDTH=4,AXI_ADDR_WIDTH=28,AXI_DATA_WIDTH=128))
    stub='`timescale 1ns/1ps\n'
    for name,ps in [(CPU_MODULE,soc),('ddr3_top',ddr)]:
        stub+='module '+name+'('+','.join(declaration(d,w,n) for n,(d,w) in ps.items())+');\n'
        stub+='initial begin\n'+''.join(n+"='0;\n" for n,(d,w) in ps.items() if d=='output')+'end\n'
        if name=='ddr3_top':
            stub+='''
    reg [127:0] stored;
    reg aw_seen,w_seen;
    reg [3:0] write_id;
    reg [1:0] response=0;
    integer reads=0,writes=0;
    always @* begin
        s_axi_arready=cal_done && !s_axi_rvalid;
        s_axi_awready=cal_done && !aw_seen && s_axi_wvalid;
        s_axi_wready=cal_done && !w_seen;
    end
    always @(posedge core_clk) begin
        if(!rstn) begin
            s_axi_rvalid<=0;s_axi_bvalid<=0;aw_seen<=0;w_seen<=0;
            stored<=0;reads<=0;writes<=0;
        end else begin
            if(s_axi_rvalid && s_axi_rready)s_axi_rvalid<=0;
            if(s_axi_arvalid && s_axi_arready)begin
                if(s_axi_arlen!=0 || s_axi_arsize!=4 || s_axi_araddr[3:0]!=0)
                    $fatal(1,"C39 seam DDR-double only accepts aligned full-width single beats");
                s_axi_rvalid<=1;s_axi_rlast<=1;s_axi_rid<=s_axi_arid;
                s_axi_rdata<=stored;s_axi_rresp<=response;reads<=reads+1;
            end
            if(s_axi_awvalid && s_axi_awready)begin aw_seen<=1;write_id<=s_axi_awid;end
            if(s_axi_wvalid && s_axi_wready)begin
                if(!s_axi_wlast || s_axi_wstrb!=16'hffff)$fatal(1,"bad write fixture");
                w_seen<=1;stored<=s_axi_wdata;
            end
            if(aw_seen && w_seen && !s_axi_bvalid)begin
                s_axi_bvalid<=1;s_axi_bid<=write_id;s_axi_bresp<=response;writes<=writes+1;
            end
            if(s_axi_bvalid && s_axi_bready)begin s_axi_bvalid<=0;aw_seen<=0;w_seen<=0;end
        end
    end
'''
        stub+='endmodule\n'
    top=ROOT/'efinity'/f'{NAME}.sv'
    ps=ports(top,NAME,180,{})
    tb='`timescale 1ns/1ps\nmodule tb_c38_joint; reg clk=0,cam=0,reset_n=0; always #5 clk=~clk; always #7 cam=~cam;\n'
    tb+=NAME+' dut('+','.join('.'+n+'('+('clk' if n=='core_clk' else 'cam' if n=='cam_clk' else 'reset_n' if n=='reset_n' else "'0" if d=='input' else '')+')' for n,(d,w) in ps.items())+');\n'
    tb+='''
    localparam [127:0] DATA=128'h0123456789abcdef_ffeeddccbbaa9988;
    integer checks=0,cycles=0;
    always @(posedge clk)begin cycles<=cycles+1;if(cycles>3000)$fatal(1,"seam timeout");end
    task read_once(input [7:0] id,input [31:0] address,input [1:0] expected);
        integer before_reads;
        begin
            before_reads=dut.u_ddr.reads;
            @(negedge clk);dut.u_soc.io_ddrA_ar_payload_id=id;
            dut.u_soc.io_ddrA_ar_payload_addr=address;dut.u_soc.io_ddrA_ar_payload_size=4;
            dut.u_soc.io_ddrA_ar_payload_burst=1;dut.u_soc.io_ddrA_ar_valid=1;
            do @(posedge clk);while(!dut.u_soc.io_ddrA_ar_ready);
            @(negedge clk);dut.u_soc.io_ddrA_ar_valid=0;
            wait(dut.u_soc.io_ddrA_r_valid);
            if(dut.u_soc.io_ddrA_r_payload_id!==id || dut.u_soc.io_ddrA_r_payload_resp!==expected ||
               !dut.u_soc.io_ddrA_r_payload_last)$fatal(1,"C39 read identity/response wiring");
            if(expected==0 && dut.u_soc.io_ddrA_r_payload_data!==DATA)$fatal(1,"C39 read data wiring");
            repeat(3)begin @(posedge clk);if(!dut.u_soc.io_ddrA_r_valid)$fatal(1,"held R lost");end
            @(negedge clk);dut.u_soc.io_ddrA_r_ready=1;
            @(posedge clk);@(negedge clk);dut.u_soc.io_ddrA_r_ready=0;
            if(expected==3 && dut.u_ddr.reads!=before_reads)$fatal(1,"out-of-range request escaped");
            checks=checks+1;
        end
    endtask
    task write_once(input [7:0] id,input [1:0] expected);
        reg aw_done,w_done;
        begin
            @(negedge clk);dut.u_soc.io_ddrA_aw_payload_id=id;dut.u_soc.io_ddrA_aw_payload_addr=32'h08001000;
            dut.u_soc.io_ddrA_aw_payload_size=4;dut.u_soc.io_ddrA_aw_payload_burst=1;
            dut.u_soc.io_ddrA_aw_valid=1;dut.u_soc.io_ddrA_w_valid=1;
            dut.u_soc.io_ddrA_w_payload_data=DATA;dut.u_soc.io_ddrA_w_payload_strb=16'hffff;
            dut.u_soc.io_ddrA_w_payload_last=1;aw_done=0;w_done=0;
            while(!aw_done || !w_done)begin
                @(posedge clk);if(dut.u_soc.io_ddrA_aw_ready)aw_done=1;if(dut.u_soc.io_ddrA_w_ready)w_done=1;
                @(negedge clk);if(aw_done)dut.u_soc.io_ddrA_aw_valid=0;if(w_done)dut.u_soc.io_ddrA_w_valid=0;
            end
            wait(dut.u_soc.io_ddrA_b_valid);
            if(dut.u_soc.io_ddrA_b_payload_id!==id || dut.u_soc.io_ddrA_b_payload_resp!==expected)
                $fatal(1,"C39 write identity/BRESP wiring");
            repeat(3)@(posedge clk);
            @(negedge clk);dut.u_soc.io_ddrA_b_ready=1;
            @(posedge clk);@(negedge clk);dut.u_soc.io_ddrA_b_ready=0;checks=checks+1;
        end
    endtask
    task apb_read(input [15:0] address,input [31:0] expected,input error);
        begin
            @(negedge clk);dut.u_soc.io_apbSlave_0_PADDR=address;
            dut.u_soc.io_apbSlave_0_PSEL=1;dut.u_soc.io_apbSlave_0_PENABLE=0;
            @(negedge clk);dut.u_soc.io_apbSlave_0_PENABLE=1;
            @(posedge clk);
            if(!dut.u_soc.io_apbSlave_0_PREADY || dut.u_soc.io_apbSlave_0_PSLVERROR!==error ||
               dut.u_soc.io_apbSlave_0_PRDATA!==expected)$fatal(1,"C39 APB decode wiring");
            @(negedge clk);dut.u_soc.io_apbSlave_0_PSEL=0;dut.u_soc.io_apbSlave_0_PENABLE=0;checks=checks+1;
        end
    endtask
    initial begin
        repeat(5)@(negedge clk);reset_n=1;
        repeat(6)@(negedge clk);
        apb_read(16'h0100,32'h52324831,0);
        apb_read(16'h0038,32'h01e00280,0);
        apb_read(16'h1100,0,1);
        dut.u_soc.io_ddrA_ar_valid=1;
        repeat(5)begin @(posedge clk);if(dut.cpu_arvalid || dut.u_soc.io_ddrA_ar_ready)$fatal(1,"CPU escaped calibration gate");end
        @(negedge clk);dut.u_soc.io_ddrA_ar_valid=0;dut.u_ddr.cal_done=1;
        repeat(6)@(negedge clk);
        write_once(8'ha5,0);read_once(8'hd4,32'h08001000,0);
        dut.u_ddr.response=2;write_once(8'hf3,2);read_once(8'h87,32'h08001000,2);
        read_once(8'hc1,32'h10000000,3);
        if(dut.cpu_adapter_fault)$fatal(1,"unexpected adapter protocol fault");
        force dut.u_host.irq=1'b1;#1;if(dut.u_soc.userInterruptA!==1'b1)$fatal(1,"C39 scalar IRQ wiring");
        release dut.u_host.irq;checks=checks+1;
        $display("C39_JOINT_SEAM_PASS checks=%0d ddr_reads=%0d ddr_writes=%0d full_id=1 bresp_error=1 calibration_gate=1 high_address_rejected=1 apb=1 irq_wire=1 actual_host_RTL=1 actual_vendor_execution=0",checks,dut.u_ddr.reads,dut.u_ddr.writes);
        $finish;
    end
endmodule
'''
    with tempfile.TemporaryDirectory(prefix='c39_seam_',dir=ROOT/'sim') as td:
        td=Path(td);(td/'stubs.sv').write_text(stub);(td/'tb.sv').write_text(tb)
        actual=top.read_text()
        variants=[('positive',actual,None)]
        for old,new,fatal in (
            ('.io_ddrA_b_payload_resp(cpu_bresp)',".io_ddrA_b_payload_resp(2'b00)",'C39 write identity/BRESP wiring'),
            ('.io_ddrA_r_payload_id(cpu_rid)',".io_ddrA_r_payload_id({4'b0,cpu_rid[3:0]})",'C39 read identity/response wiring'),
            ('assign cpu_arvalid=soc_arvalid && cal_ready;','assign cpu_arvalid=soc_arvalid;','CPU escaped calibration gate')):
            if actual.count(old)!=1:raise ValueError('missing exact negative seam')
            variants.append((fatal,actual.replace(old,new),fatal))
        for label,source,fatal in variants:
            (td/'joint.sv').write_text(source)
            cmd=['D:/iverilog/bin/iverilog.exe','-g2012','-s','tb_c38_joint','-o',str(td/'run.vvp'),
                 *map(str,sources()),str(td/'joint.sv'),str(td/'stubs.sv'),str(td/'tb.sv')]
            compiled=subprocess.run(cmd,capture_output=True,text=True,timeout=90)
            if compiled.returncode:raise RuntimeError(compiled.stderr[-5000:])
            result=subprocess.run(['D:/iverilog/bin/vvp.exe',str(td/'run.vvp')],capture_output=True,text=True,timeout=90)
            if fatal:
                if result.returncode==0 or fatal not in result.stdout:
                    raise RuntimeError('actual wiring corruption was not detected: '+label)
                print('C39_ACTUAL_WIRING_NEGATIVE_PASS '+fatal)
            else:
                if result.returncode or 'C39_JOINT_SEAM_PASS' not in result.stdout:
                    raise RuntimeError((result.stdout+result.stderr)[-5000:])
                print(result.stdout.strip())
    print('C39_SEAM_CLEAN temporary_directory_removed=1 waves_written=0')


if __name__=='__main__':main()

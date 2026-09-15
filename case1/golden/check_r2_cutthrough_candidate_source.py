"""C32 source-only invariants. This does not compile or simulate the RTL."""
import re
import run_r2_rgb2_host_probe as c31


def normalized(s):return re.sub(r'\s+','',s)


def main():
    old=(c31.ROOT/'rtl/r2/c1_r2_tensor_pingpong_writer.sv').read_text(encoding='utf-8-sig')
    new=(c31.ROOT/'rtl/r2/c1_r2_tensor_cutthrough_writer.sv').read_text(encoding='utf-8-sig')
    old_ports=old.split('module c1_r2_tensor_pingpong_writer (',1)[1].split(');',1)[0]
    new_ports=new.split('module c1_r2_tensor_cutthrough_writer (',1)[1].split(');',1)[0]
    assert normalized(old_ports)==normalized(new_ports),'writer port contract changed'
    anchor='for(genvar b=0;b<16;b=b+1) begin : g_byte_bank'
    assert old.split(anchor,1)[1].split('always_ff',1)[0]==new.split(anchor,1)[1].split('always_ff',1)[0], 'byte RAM or output mask changed'
    assert old.split('RESPONSE:if(retire) begin',1)[1].split('default:',1)[0]==new.split('RESPONSE:if(retire) begin',1)[1].split('default:',1)[0], 'real response retirement changed'
    compact=normalized(new)
    for required in ('assignresponse_ready=!rst&&state==RESPONSE&&completed[send_page];',
                     'read_index<ready_words[send_page]', 'if(!held_valid||data_ready)begin',
                     'logic[10:0]ready_words[0:1];'):
        assert required in compact,required
    assert len(c31.SOURCES)==45 and 'rtl/r2/c1_r2_tensor_pingpong_writer.sv' in c31.SOURCES
    assert all('cutthrough' not in s for s in c31.SOURCES),'unverified candidate inserted into C31'
    print('C32_WRITER_SOURCE_ONLY_PASS identical_ports=1 identical_byte_RAM_and_mask=1 real_response_release_retained=1 C31_sources_unchanged=45 RTL_compiled=0 RTL_simulated=0 PNR_done=0')


if __name__=='__main__':main()

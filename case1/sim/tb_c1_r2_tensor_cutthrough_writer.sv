`timescale 1ns/1ps
// C32 independent row-interface test. Both writers see the same accepted
// producer packets; each output is checked against a separately packed oracle.
// This is not a physical AXI/DDR or whole-CNN throughput measurement.
module tb_c1_r2_tensor_cutthrough_writer;
    parameter integer MODE=0,CHANNELS=8,WIDTH=16,PACKETS=22,WORDS=8,ROWS=4;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,drive_start=0,drive_valid=0;
    reg [31:0] start_address=0;
    reg [70:0] packet=0;
    reg [70:0] packets_mem[0:16383];
    reg [127:0] expected_mem[0:8191];
    wire [1:0] start_ready,in_ready,cmd_valid,cmd_ready,data_valid,data_ready,data_last;
    wire [1:0] response_valid,response_ready,response_error,done,error;
    wire [31:0] cmd_address[0:1];wire [15:0] cmd_beats[0:1];
    wire [127:0] data[0:1];
    integer cycle=0,started=0,producer_row=0;
    integer source_last_cycle[0:ROWS-1];
    integer command_count[0:1],ack_count[0:1],done_count[0:1],words_seen[0:1];
    integer early_words[0:1],early_response_stalls[0:1],max_debt[0:1];
    wire common_start=drive_start && (&start_ready);
    wire common_valid=drive_valid && (&in_ready);
    wire stream_enable=cycle%19<15;
    c1_r2_tensor_pingpong_writer reference_writer (
        .clk(clk),.rst(rst),.start_valid(common_start),.start_ready(start_ready[0]),.stream_enable(stream_enable),
        .start_mode(3'(MODE)),.start_width(11'(WIDTH)),.start_channels(6'(CHANNELS)),.start_rgb(MODE==1),.start_address(start_address),
        .in_valid(common_valid),.in_ready(in_ready[0]),.in_data(packet[47:0]),.in_mask(packet[53:48]),.in_index(packet[69:54]),.in_last(packet[70]),
        .cmd_valid(cmd_valid[0]),.cmd_ready(cmd_ready[0]),.cmd_address(cmd_address[0]),.cmd_beats(cmd_beats[0]),
        .data_valid(data_valid[0]),.data_ready(data_ready[0]),.data(data[0]),.data_last(data_last[0]),
        .response_valid(response_valid[0]),.response_error(response_error[0]),.response_ready(response_ready[0]),.done(done[0]),.error(error[0]));
    c1_r2_tensor_cutthrough_writer candidate_writer (
        .clk(clk),.rst(rst),.start_valid(common_start),.start_ready(start_ready[1]),.stream_enable(stream_enable),
        .start_mode(3'(MODE)),.start_width(11'(WIDTH)),.start_channels(6'(CHANNELS)),.start_rgb(MODE==1),.start_address(start_address),
        .in_valid(common_valid),.in_ready(in_ready[1]),.in_data(packet[47:0]),.in_mask(packet[53:48]),.in_index(packet[69:54]),.in_last(packet[70]),
        .cmd_valid(cmd_valid[1]),.cmd_ready(cmd_ready[1]),.cmd_address(cmd_address[1]),.cmd_beats(cmd_beats[1]),
        .data_valid(data_valid[1]),.data_ready(data_ready[1]),.data(data[1]),.data_last(data_last[1]),
        .response_valid(response_valid[1]),.response_error(response_error[1]),.response_ready(response_ready[1]),.done(done[1]),.error(error[1]));
    for(genvar u=0;u<2;u=u+1)begin : g_sink
        reg active=0,pending_b=0,previous_retire=0,previous_error=0;
        reg held_cmd=0,held_data=0;
        reg [31:0] held_address=0;reg [15:0] held_beats=0;
        reg [127:0] held_value=0;reg held_last=0;
        integer row=0,beat=0,due=0;
        assign cmd_ready[u]=!rst && !active && !pending_b && cycle%7!=0;
        assign data_ready[u]=!rst && active && cycle%5!=1 && cycle%11!=3;
        assign response_valid[u]=!rst && pending_b && cycle>=due;
        assign response_error[u]=row==1;
        always @(posedge clk)begin
            if(rst)begin
                active<=0;pending_b<=0;previous_retire<=0;previous_error<=0;
                row<=0;beat<=0;due<=0;held_cmd<=0;held_data<=0;
                command_count[u]<=0;ack_count[u]<=0;done_count[u]<=0;words_seen[u]<=0;
                early_words[u]<=0;early_response_stalls[u]<=0;max_debt[u]<=0;
            end else begin
                if(started-ack_count[u]>2)$fatal(1,"writer released a page before response unit=%0d",u);
                if(started-ack_count[u]>max_debt[u])max_debt[u]<=started-ack_count[u];
                if(held_cmd && (!cmd_valid[u] || {cmd_address[u],cmd_beats[u]}!=={held_address,held_beats}))$fatal(1,"unstable row command");
                if(held_data && (!data_valid[u] || {data[u],data_last[u]}!=={held_value,held_last}))$fatal(1,"unstable row data");
                held_cmd<=cmd_valid[u]&&!cmd_ready[u];held_address<=cmd_address[u];held_beats<=cmd_beats[u];
                held_data<=data_valid[u]&&!data_ready[u];held_value<=data[u];held_last<=data_last[u];
                if(cmd_valid[u]&&cmd_ready[u])begin
                    if(row>=ROWS || cmd_address[u]!==32'h10000+row*32'h4000 || cmd_beats[u]!=WORDS)$fatal(1,"row descriptor mismatch");
                    active<=1;beat<=0;command_count[u]<=command_count[u]+1;
                end
                if(data_valid[u]&&data_ready[u])begin
                    if(data[u]!==expected_mem[row*WORDS+beat] || data_last[u]!=(beat==WORDS-1))
                        $fatal(1,"writer golden mismatch unit=%0d row=%0d beat=%0d got=%h expected=%h",u,row,beat,data[u],expected_mem[row*WORDS+beat]);
                    if(source_last_cycle[row]<0)early_words[u]<=early_words[u]+1;
                    words_seen[u]<=words_seen[u]+1;beat<=beat+1;
                    if(beat==WORDS-1)begin
                        active<=0;pending_b<=1;
                        // Row zero offers the odd-DW response before its
                        // delayed empty LAST. Later rows delay the response
                        // past LAST so both page credits are exercised too.
                        // Fast legal retire/reallocate on one edge can
                        // otherwise keep the candidate's observed debt at 1.
                        due<=cycle+((MODE==2 && WIDTH%2==1 && row==0) ? 2 : 96)+row;
                    end
                end
                if(response_valid[u]&&!response_ready[u] && source_last_cycle[row]<0)early_response_stalls[u]<=early_response_stalls[u]+1;
                if(response_valid[u]&&response_ready[u])begin
                    if(source_last_cycle[row]<0)$fatal(1,"response retired before producer last");
                    pending_b<=0;ack_count[u]<=ack_count[u]+1;row<=row+1;
                end
                if(done[u]!==previous_retire || (done[u] && error[u]!==previous_error))$fatal(1,"done/error not tied to actual row response");
                previous_retire<=response_valid[u]&&response_ready[u];previous_error<=response_error[u];
                if(done[u])done_count[u]<=done_count[u]+1;
            end
        end
    end
    always @(posedge clk)begin
        if(rst)begin cycle<=0;started<=0;producer_row<=0;end
        else begin
            cycle<=cycle+1;
            if(common_start)started<=started+1;
            if(common_valid && packet[70])begin source_last_cycle[producer_row]=cycle;producer_row<=producer_row+1;end
            if(cycle>100000)$fatal(1,"writer test timeout");
        end
    end
    reg [4095:0] directory,path;
    initial begin
        if(!$value$plusargs("DIR=%s",directory))$fatal(1,"missing writer vectors");
        if(PACKETS*ROWS>16384 || WORDS*ROWS>8192)$fatal(1,"writer fixture too large");
        $sformat(path,"%0s/packets.mem",directory);$readmemh(path,packets_mem,0,PACKETS*ROWS-1);
        $sformat(path,"%0s/expected.mem",directory);$readmemh(path,expected_mem,0,WORDS*ROWS-1);
        if((^packets_mem[PACKETS*ROWS-1])===1'bx || (^expected_mem[WORDS*ROWS-1])===1'bx)$fatal(1,"missing writer oracle tail");
        for(integer r=0;r<ROWS;r=r+1)source_last_cycle[r]=-1;
        repeat(5)@(negedge clk);rst=0;
        for(integer r=0;r<ROWS;r=r+1)begin
            while(!(&start_ready))@(negedge clk);
            start_address=32'h10000+r*32'h4000;drive_start=1;
            @(negedge clk);drive_start=0;
            for(integer i=0;i<PACKETS;i=i+1)begin
                // DW odd tails have an empty final phase. All bytes can be
                // sent before it, but a response MUST remain unacknowledged.
                if(MODE==2 && WIDTH%2==1 && i==PACKETS-1)repeat(64)@(negedge clk);
                while(!(&in_ready))@(negedge clk);
                packet=packets_mem[r*PACKETS+i];drive_valid=1;
                @(negedge clk);drive_valid=0;
                if((i+r)%4==1)repeat(2)@(negedge clk);
            end
        end
        while(done_count[0]!=ROWS || done_count[1]!=ROWS)@(negedge clk);
        repeat(4)@(negedge clk);
        for(integer u=0;u<2;u=u+1)begin
            if(command_count[u]!=ROWS || ack_count[u]!=ROWS || words_seen[u]!=ROWS*WORDS || max_debt[u]!=2)
                $fatal(1,"writer ownership/data coverage incomplete mode=%0d channels=%0d width=%0d unit=%0d commands=%0d acks=%0d words=%0d expected_words=%0d peak_debt=%0d",MODE,CHANNELS,WIDTH,u,command_count[u],ack_count[u],words_seen[u],ROWS*WORDS,max_debt[u]);
        end
        if(early_words[0]!=0 || (WIDTH>=16 && early_words[1]==0))$fatal(1,"cutthrough not demonstrated");
        if(MODE==2 && WIDTH%2==1 && early_response_stalls[1]==0)$fatal(1,"odd tail response hold not exercised");
        $display("C32_WRITER_RTL_PASS mode=%0d channels=%0d width=%0d rows=%0d words_each=%0d candidate_early_words=%0d odd_tail_response_stalls=%0d retained_reference=1 golden_both=1 response_errors=2 page_debt_peak=2 actual_AXI=0",MODE,CHANNELS,WIDTH,ROWS,WORDS*ROWS,early_words[1],early_response_stalls[1]);
        $finish;
    end
endmodule

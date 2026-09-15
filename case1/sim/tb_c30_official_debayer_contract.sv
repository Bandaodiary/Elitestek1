`timescale 1ns/1ps
// Characterize the ACTIVE vendor source closure, never an inferred replacement.
module tb_c30_official_debayer_contract;
    parameter bit BAD_RAW_PACKING=0;
    reg in_pclk=0,in_rstn=0;
    always #7.143 in_pclk=~in_pclk;
    reg raw_vs_i=0,raw_hs_i=0,raw_de_i=0,raw_valid_i=0;
    reg [15:0] raw_datax4_i=0;
    wire rgb_vs_o,rgb_hs_o,rgb_de_o,rgb_valid_o;
    wire [47:0] rgb_datax2_o;
    debayer_top_2to1 dut(.*);
    integer frame_id=0,row_id=0,pair_id=0,mode=0;
    integer emitted=0,observed=0,checks=0,golden_pairs=0;
    reg [7:0] expected_left,expected_right;
    reg [47:0] expected_rgb;
    reg [3:0] control_pipe[0:4];
    integer frame_pipe[0:4],row_pipe[0:4],pair_pipe[0:4],mode_pipe[0:4];
    function automatic [7:0] raw_pixel(input integer x,y,m);
        if(m==0)raw_pixel=8*(x+1);
        else raw_pixel=y%2 ? (x%2 ? 8'd32 : 8'd96) : (x%2 ? 8'd96 : 8'd160);
    endfunction
    always @(posedge in_pclk)begin
        control_pipe[0]<={raw_vs_i,raw_hs_i,raw_de_i,raw_valid_i};
        frame_pipe[0]<=frame_id;row_pipe[0]<=row_id;pair_pipe[0]<=pair_id;mode_pipe[0]<=mode;
        for(integer i=1;i<5;i++)begin
            control_pipe[i]<=control_pipe[i-1];frame_pipe[i]<=frame_pipe[i-1];
            row_pipe[i]<=row_pipe[i-1];pair_pipe[i]<=pair_pipe[i-1];mode_pipe[i]<=mode_pipe[i-1];
        end
        if(in_rstn && raw_valid_i)emitted=emitted+1;
        #1;
        if(in_rstn)begin
            if({rgb_vs_o,rgb_hs_o,rgb_de_o,rgb_valid_o}!==control_pipe[4])
                $fatal(1,"official sync/data-valid latency differs from five-register contract");
            checks=checks+1;
            if(rgb_valid_o)begin
                observed=observed+1;
                if(row_pipe[4]==5)$display("C30_OFFICIAL_SAMPLE mode=%0d frame=%0d row=%0d pair=%0d low=%h high=%h",mode_pipe[4],frame_pipe[4],row_pipe[4],pair_pipe[4],rgb_datax2_o[23:0],rgb_datax2_o[47:24]);
                if(row_pipe[4]>=3 && (^rgb_datax2_o===1'bx))$fatal(1,"unknown official steady-row RGB");
                if(row_pipe[4]>=3 && pair_pipe[4]>=2)begin
                    // Interior linear grayscale must reconstruct the previous
                    // pair, low/left then high/right; flat RGGB is R160/G96/B32.
                    expected_left=8*(2*pair_pipe[4]-1);expected_right=8*(2*pair_pipe[4]);
                    expected_rgb=mode_pipe[4]==0 ? {expected_right,expected_right,expected_right,
                        expected_left,expected_left,expected_left} : 48'ha06020a06020;
                    if(rgb_datax2_o!==expected_rgb)$fatal(1,"official RGB golden mismatch mode=%0d row=%0d pair=%0d got=%h expected=%h",mode_pipe[4],row_pipe[4],pair_pipe[4],rgb_datax2_o,expected_rgb);
                    golden_pairs=golden_pairs+1;
                end
            end
        end
    end
    initial begin
        repeat(10)@(negedge in_pclk);in_rstn=1;
        for(mode=0;mode<2;mode=mode+1)for(frame_id=0;frame_id<2;frame_id=frame_id+1)begin
            @(negedge in_pclk);raw_vs_i=1;repeat(3)@(negedge in_pclk);raw_vs_i=0;
            repeat(8)@(negedge in_pclk);
            for(row_id=0;row_id<8;row_id=row_id+1)begin
                raw_hs_i=1;repeat(2)@(negedge in_pclk);raw_hs_i=0;
                repeat(4)@(negedge in_pclk);
                for(pair_id=0;pair_id<8;pair_id=pair_id+1)begin
                    raw_de_i=1;raw_valid_i=1;
                    // The active top swaps the frame-buffer low/high bytes
                    // before this port: RAW first-in-raster is the HIGH byte.
                    raw_datax4_i=BAD_RAW_PACKING ? {raw_pixel(pair_id*2+1,row_id,mode),raw_pixel(pair_id*2,row_id,mode)} :
                        {raw_pixel(pair_id*2,row_id,mode),raw_pixel(pair_id*2+1,row_id,mode)};
                    @(negedge in_pclk);
                end
                raw_de_i=0;raw_valid_i=0;raw_datax4_i=0;
                repeat(8)@(negedge in_pclk);
            end
            repeat(12)@(negedge in_pclk);
        end
        repeat(10)@(negedge in_pclk);
        if(emitted!=256 || observed!=emitted || golden_pairs!=120)$fatal(1,"official pair count mismatch");
        $display("C30_OFFICIAL_INTERIOR_GOLDEN_PASS pairs=%0d scalar_pixels=%0d low_first=1 horizontal_pair_delay=1 flat_r=160 flat_g=96 flat_b=32",golden_pairs,2*golden_pairs);
        $display("C30_OFFICIAL_CONTROL_PASS frames=4 source_pairs=%0d output_pairs=%0d checks=%0d delay_registers=5",emitted,observed,checks);
        $finish;
    end
    initial begin #1000000;$fatal(1,"official contract timeout");end
endmodule

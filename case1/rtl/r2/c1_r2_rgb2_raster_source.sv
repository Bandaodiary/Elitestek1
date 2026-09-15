`timescale 1ns/1ps
// Registered source-domain boundary adapter for the active demo's 2xRGB port.
// LOW 24 bits = first/left RGB pixel, HIGH 24 bits = second/right RGB pixel.
// Input must have de==valid; bubbles INSIDE a DE line are not this ABI.
// Positive VS is the blanking sync pulse, not an active-video frame marker.
// Ignore startup partial frames until VS. Withhold the LAST source pair until
// the NEXT VS assertion proves exact line/pair counts and no extra active data.
// No ready, no clock conversion. A separate pair ingress owns CDC and errors.
module c1_r2_rgb2_raster_source #(
    parameter integer SOURCE_WIDTH=1920,SOURCE_HEIGHT=1080,
    parameter bit VS_ACTIVE_HIGH=1
) (
    input wire clk,rst,in_vs,in_de,in_valid,
    input wire [47:0] in_rgb,
    output logic pair_valid,pair_sof,pair_eol,pair_eof,pair_error,
    output logic [47:0] pair_rgb
);
    localparam integer PAIRS=SOURCE_WIDTH/2;
    localparam GEOMETRY_OK=SOURCE_WIDTH>=2 && SOURCE_WIDTH<=65534 &&
        SOURCE_WIDTH%2==0 && SOURCE_HEIGHT>=1 && SOURCE_HEIGHT<=65534;
    wire vs_active=VS_ACTIVE_HIGH ? in_vs : !in_vs;
    logic vs_q,armed_q,frame_q,bad_q,line_q,last_q,last_sof_q;
    logic [15:0] x_q,y_q;
    logic [47:0] last_rgb_q;
    wire [15:0] current_x=line_q ? x_q : 16'd0;
    wire close_line=line_q && !in_de && !in_valid && x_q==PAIRS;
    wire [16:0] closed_rows={1'b0,y_q}+close_line;
    always_ff @(posedge clk)begin
        if(rst)begin
            vs_q<=0;armed_q<=0;frame_q<=0;bad_q<=0;line_q<=0;last_q<=0;last_sof_q<=0;
            x_q<=0;y_q<=0;last_rgb_q<=0;
            pair_valid<=0;pair_sof<=0;pair_eol<=0;pair_eof<=0;pair_error<=0;pair_rgb<=0;
        end else begin
            vs_q<=vs_active;
            pair_valid<=0;pair_sof<=0;pair_eol<=0;pair_eof<=0;pair_error<=0;
            if(vs_active)begin
                if(!vs_q && frame_q && !bad_q)begin
                    if(!in_de && !in_valid && last_q && (!line_q || close_line) && closed_rows==SOURCE_HEIGHT)begin
                        pair_valid<=1;pair_sof<=last_sof_q;pair_eol<=1;pair_eof<=1;pair_rgb<=last_rgb_q;
                    end else pair_error<=1;
                end
                // A sync pulse closes one frame and arms the next; reset is NOT
                // asserted per frame and no downstream FIFO pointer is changed.
                armed_q<=GEOMETRY_OK;frame_q<=0;bad_q<=0;line_q<=0;last_q<=0;
                x_q<=0;y_q<=0;
            end else if(armed_q && !bad_q)begin
                if(in_de!=in_valid)begin bad_q<=1;pair_error<=1;end
                else if(in_valid)begin
                    if(y_q>=SOURCE_HEIGHT || current_x>=PAIRS)begin bad_q<=1;pair_error<=1;end
                    else begin
                        frame_q<=1;line_q<=1;x_q<=current_x+1'b1;
                        if(y_q==SOURCE_HEIGHT-1 && current_x==PAIRS-1)begin
                            last_q<=1;last_sof_q<=!frame_q;last_rgb_q<=in_rgb;
                        end else begin
                            pair_valid<=1;pair_sof<=!frame_q;
                            pair_eol<=current_x==PAIRS-1;pair_rgb<=in_rgb;
                        end
                    end
                end else if(line_q)begin
                    line_q<=0;x_q<=0;
                    if(x_q!=PAIRS)begin bad_q<=1;pair_error<=1;end
                    else y_q<=y_q+1'b1;
                end
            end
        end
    end
`ifndef SYNTHESIS
    initial if(!GEOMETRY_OK)$fatal(1,"RGB2 raster requires even width 2..65534 and height 1..65534");
    always @(posedge clk)if(!rst && pair_valid && pair_error)$fatal(1,"RGB2 emitted data and error together");
`endif
endmodule

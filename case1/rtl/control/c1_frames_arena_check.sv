// Check active XRGB rows against one half-open continuous reserved arena.
// Snapshot at req handshake; 49-bit serial extent calculation prevents wrap.
// code 1=frame geometry, 2=arena/extent, 3=active-row overlap. No AXI traffic.
module c1_frames_arena_check #(
    parameter integer FRAMES=1,
    parameter integer INDEX_BITS=(FRAMES<2 ? 1 : $clog2(FRAMES))
) (
    input logic clk,rst,cancel,req_valid,
    output wire req_ready,
    input logic [32:0] arena_begin,arena_end,
    input logic [FRAMES-1:0] frame_valid,
    input logic [FRAMES-1:0][31:0] frame_base,frame_stride,
    input logic [FRAMES-1:0][15:0] frame_width,frame_height,
    output wire busy,
    output logic rsp_valid,
    input logic rsp_ready,
    output logic [1:0] error_code,
    output logic [INDEX_BITS-1:0] error_index
);
    typedef enum logic [2:0] {IDLE,BASIC,EXTENT,SCAN,NEXT_FRAME} state_t;
    state_t state;
    logic [32:0] begin_q,end_q,row_start_q;
    logic [FRAMES-1:0] valid_q;
    logic [FRAMES-1:0][31:0] base_q,stride_q;
    logic [FRAMES-1:0][15:0] width_q,height_q;
    logic [INDEX_BITS-1:0] frame_q;
    logic [15:0] multiplier_q,row_q;
    logic [4:0] bit_q;
    logic [48:0] sum_q,addend_q;
    wire [31:0] selected_base=base_q[frame_q],selected_stride=stride_q[frame_q];
    wire [15:0] selected_width=width_q[frame_q];
    wire [48:0] sum_next=sum_q+(multiplier_q[0] ? addend_q : 49'd0);
    wire [32:0] row_end=row_start_q+{15'd0,width_q[frame_q],2'b00};
    assign busy=(state!=IDLE);
    assign req_ready=!rst&&!cancel&&!busy&&(!rsp_valid||rsp_ready);
    always_ff @(posedge clk) begin
        if(rst||cancel) begin
            state<=IDLE;begin_q<=0;end_q<=0;row_start_q<=0;
            valid_q<=0;base_q<='0;stride_q<='0;width_q<='0;height_q<='0;
            frame_q<=0;multiplier_q<=0;row_q<=0;bit_q<=0;sum_q<=0;addend_q<=0;
            rsp_valid<=0;error_code<=0;error_index<=0;
        end else begin
            if(rsp_valid&&rsp_ready) rsp_valid<=0;
            case(state)
                IDLE: if(req_valid&&req_ready) begin
                    begin_q<=arena_begin;end_q<=arena_end;valid_q<=frame_valid;
                    base_q<=frame_base;stride_q<=frame_stride;width_q<=frame_width;height_q<=frame_height;
                    frame_q<=0;error_code<=0;error_index<=0;state<=BASIC;
                end
                BASIC: begin
                    if(begin_q>=end_q||end_q>33'h1_0000_0000) begin
                        error_code<=2;error_index<=frame_q;rsp_valid<=1;state<=IDLE;
                    end else if(!valid_q[frame_q]) state<=NEXT_FRAME;
                    else if(width_q[frame_q]==0||height_q[frame_q]==0||selected_width[1:0]!=0||
                            selected_base[3:0]!=0||selected_stride[3:0]!=0||
                            stride_q[frame_q]<{14'd0,width_q[frame_q],2'b00}) begin
                        error_code<=1;error_index<=frame_q;rsp_valid<=1;state<=IDLE;
                    end else begin
                        sum_q<={17'd0,base_q[frame_q]}+{31'd0,width_q[frame_q],2'b00};
                        addend_q<={17'd0,stride_q[frame_q]};multiplier_q<=height_q[frame_q]-1'b1;
                        bit_q<=0;state<=EXTENT;
                    end
                end
                EXTENT: begin
                    sum_q<=sum_next;addend_q<=addend_q<<1;multiplier_q<=multiplier_q>>1;
                    if(bit_q==15) begin
                        if(sum_next>49'h1_0000_0000) begin
                            error_code<=2;error_index<=frame_q;rsp_valid<=1;state<=IDLE;
                        end else if(sum_next<={16'd0,begin_q}||{1'b0,base_q[frame_q]}>=end_q)
                            state<=NEXT_FRAME;
                        else begin row_start_q<={1'b0,base_q[frame_q]};row_q<=0;state<=SCAN;end
                    end else bit_q<=bit_q+1'b1;
                end
                SCAN: begin
                    if(row_start_q<end_q&&begin_q<row_end) begin
                        error_code<=3;error_index<=frame_q;rsp_valid<=1;state<=IDLE;
                    end else if(row_start_q>=end_q||row_q==height_q[frame_q]-1'b1)
                        state<=NEXT_FRAME;
                    else begin row_q<=row_q+1'b1;row_start_q<=row_start_q+{1'b0,stride_q[frame_q]};end
                end
                NEXT_FRAME: begin
                    if(frame_q==FRAMES-1) begin rsp_valid<=1;state<=IDLE;end
                    else begin frame_q<=frame_q+1'b1;state<=BASIC;end
                end
                default: state<=IDLE;
            endcase
        end
    end
endmodule

// Snapshot/preflight for three XRGB frames: input, processed, preview.
// No AXI transactions. cancel destructively discards only this local check.
// Exact active-row overlap: padding may be shared; last exclusive end may be 2^32.
// code: 1 invalid geometry/alignment, 2 extent/preview arena, 3 active overlap.
// index: frame 0/1/2 for code 1/2; pair 0=(0,1),1=(0,2),2=(1,2) for code 3.
module c1_frame_triple_layout_check #(
    parameter logic [32:0] PREVIEW_REGION_BEGIN=33'd0,
    parameter logic [32:0] PREVIEW_REGION_END=33'h1_0000_0000,
    parameter bit FAST_DISJOINT_ENVELOPE=1'b1,
    // bit 0=(0,1), bit 1=(0,2), bit 2=(1,2). For one writer against
    // two readers use 3'b011: read/read aliasing is not a write hazard.
    // Geometry, extent and arena validation still apply to ALL frames.
    parameter logic [2:0] CHECK_PAIR_MASK=3'b111
) (
    input logic clk,rst,cancel,
    input logic req_valid,output logic req_ready,
    input logic [2:0][31:0] frame_base,frame_stride,
    input logic [2:0][15:0] frame_width,frame_height,
    output logic busy,rsp_valid,input logic rsp_ready,
    output logic [1:0] error_code,error_index
);
    typedef enum logic [2:0] {IDLE,BASIC,EXTENT,PAIR_INIT,SCAN} state_t;
    state_t state;
    logic [2:0][31:0] base_q,stride_q;
    logic [2:0][15:0] width_q,height_q;
    logic [2:0][32:0] extent_q;
    logic [1:0] frame_q,pair_q,left_id,right_id;
    logic [4:0] bit_q;
    logic [15:0] multiplier_q;
    logic [48:0] sum_q,addend_q,sum_next;
    logic [32:0] left_start_q,right_start_q,left_end,right_end;
    logic [15:0] left_row_q,right_row_q;
    wire [31:0] selected_base=base_q[frame_q],selected_stride=stride_q[frame_q];
    wire [15:0] selected_width=width_q[frame_q],selected_height=height_q[frame_q];
    assign busy=(state!=IDLE);
    assign req_ready=!rst&&!cancel&&(state==IDLE)&&(!rsp_valid||rsp_ready);
    always_comb begin
        left_id=(pair_q==2 ? 2'd1 : 2'd0);
        right_id=(pair_q==0 ? 2'd1 : 2'd2);
        sum_next=sum_q+(multiplier_q[0] ? addend_q : 49'd0);
        left_end=left_start_q+{15'd0,width_q[left_id],2'b00};
        right_end=right_start_q+{15'd0,width_q[right_id],2'b00};
    end
    always_ff @(posedge clk) begin
        if(rst||cancel) begin
            state<=IDLE;rsp_valid<=0;error_code<=0;error_index<=0;
            base_q<='0;stride_q<='0;width_q<='0;height_q<='0;
            extent_q<='0;
            frame_q<=0;pair_q<=0;bit_q<=0;multiplier_q<=0;sum_q<=0;addend_q<=0;
            left_start_q<=0;right_start_q<=0;left_row_q<=0;right_row_q<=0;
        end else begin
            if(rsp_valid&&rsp_ready) rsp_valid<=0;
            case(state)
                IDLE: if(req_valid&&req_ready) begin
                    base_q<=frame_base;stride_q<=frame_stride;width_q<=frame_width;height_q<=frame_height;
                    frame_q<=0;error_code<=0;error_index<=0;state<=BASIC;
                end
                BASIC: begin
                    if(selected_width==0||selected_height==0||selected_width[1:0]!=0||
                       selected_base[3:0]!=0||selected_stride[3:0]!=0||
                       selected_stride<{14'd0,selected_width,2'b00}) begin
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
                        extent_q[frame_q]<=sum_next[32:0];
                        // Reuse the wide serial extent calculation; no second multiplier.
                        // Check the entire preview envelope, including inter-row padding.
                        if(sum_next>49'h1_0000_0000 || (frame_q==2 &&
                           (PREVIEW_REGION_BEGIN>=PREVIEW_REGION_END ||
                            PREVIEW_REGION_END>33'h1_0000_0000 ||
                            {1'b0,selected_base}<PREVIEW_REGION_BEGIN ||
                            sum_next>{16'd0,PREVIEW_REGION_END}))) begin
                            error_code<=2;error_index<=frame_q;rsp_valid<=1;state<=IDLE;
                        end else if(frame_q==2) begin pair_q<=0;state<=PAIR_INIT;end
                        else begin frame_q<=frame_q+1'b1;state<=BASIC;end
                    end else bit_q<=bit_q+1'b1;
                end
                PAIR_INIT: begin
                    left_start_q<={1'b0,base_q[left_id]};right_start_q<={1'b0,base_q[right_id]};
                    left_row_q<=0;right_row_q<=0;
                    // All three wide extents have passed validation before
                    // reaching here. Disjoint envelopes prove row disjointness;
                    // intersecting envelopes still require the exact merge walk.
                    // Keep 33 bits so exclusive 4-GiB ends never wrap to zero.
                    if(!CHECK_PAIR_MASK[pair_q]) begin
                        if(pair_q==2) begin rsp_valid<=1;state<=IDLE;end
                        else begin pair_q<=pair_q+1'b1;state<=PAIR_INIT;end
                    end else if(FAST_DISJOINT_ENVELOPE &&
                       (extent_q[left_id]<={1'b0,base_q[right_id]} ||
                        extent_q[right_id]<={1'b0,base_q[left_id]})) begin
                        if(pair_q==2) begin rsp_valid<=1;state<=IDLE;end
                        else begin pair_q<=pair_q+1'b1;state<=PAIR_INIT;end
                    end else state<=SCAN;
                end
                SCAN: begin
                    if(left_start_q<right_end&&right_start_q<left_end) begin
                        error_code<=3;error_index<=pair_q;rsp_valid<=1;state<=IDLE;
                    end else if(left_end<=right_start_q) begin
                        if(left_row_q==height_q[left_id]-1'b1) begin
                            if(pair_q==2) begin rsp_valid<=1;state<=IDLE;end
                            else begin pair_q<=pair_q+1'b1;state<=PAIR_INIT;end
                        end else begin left_row_q<=left_row_q+1'b1;left_start_q<=left_start_q+{1'b0,stride_q[left_id]};end
                    end else begin
                        if(right_row_q==height_q[right_id]-1'b1) begin
                            if(pair_q==2) begin rsp_valid<=1;state<=IDLE;end
                            else begin pair_q<=pair_q+1'b1;state<=PAIR_INIT;end
                        end else begin right_row_q<=right_row_q+1'b1;right_start_q<=right_start_q+{1'b0,stride_q[right_id]};end
                    end
                end
                default: begin state<=IDLE;rsp_valid<=0;end
            endcase
        end
    end
endmodule

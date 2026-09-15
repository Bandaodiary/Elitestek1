// Atomic image-writer admission check. The integration serializes admission
// against other writers; this module snapshots two candidates and seven held
// regions, then checks exact active rows. It owns no AXI transactions.
// Keep req_valid asserted until response; cancel discards local work/response.
module c1_frame_write_region_guard #(
    parameter bit CHECK_TENSOR_ARENA=1'b0,
    parameter bit CHECK_STATIC_ARENAS=1'b0
) (
    input logic clk,rst,cancel,req_valid,
    output wire busy,
    input logic [1:0] writer_valid,
    input logic [1:0][31:0] writer_base,writer_stride,
    input logic [1:0][15:0] writer_width,writer_height,
    input logic [6:0] held_valid,
    input logic [6:0][31:0] held_base,held_stride,
    input logic [6:0][15:0] held_width,held_height,
    output logic rsp_valid,
    output logic [7:0] error_code,
    output logic [31:0] error_address,
    input logic [32:0] tensor_begin,tensor_end,
    input logic [3:0][32:0] static_begin,static_end
);
    typedef enum logic [2:0] {IDLE,PREP,WAIT_CHECK,NEXT_PAIR,RESPONSE,ARENA_WAIT,ARENA_PREP} state_t;
    state_t state;
    logic [1:0] wvalid_q;
    logic [1:0][31:0] wb_q,ws_q;
    logic [1:0][15:0] ww_q,wh_q;
    logic [6:0] hvalid_q;
    logic [6:0][31:0] hb_q,hs_q;
    logic [6:0][15:0] hw_q,hh_q;
    logic writer_q;
    logic [1:0] group_q;
    logic [2:0] left_id,right_id;
    logic pair_present;
    logic [2:0][31:0] bases,strides;
    logic [2:0][15:0] widths,heights;
    wire check_ready,check_valid;
    wire [1:0] check_code;
    wire check_req=(state==PREP)&&wvalid_q[writer_q]&&pair_present&&!cancel&&!rst;
    assign busy=(state!=IDLE);
    wire arena_valid;
    wire [1:0] arena_code;
    wire [3:0] arena_index;
    wire arena_ready;
    logic [2:0] arena_phase_q;
    logic [32:0] tensor_begin_q,tensor_end_q;
    logic [3:0][32:0] static_begin_q,static_end_q;
    c1_frames_arena_check #(.FRAMES(9)) u_tensor_check (
        .clk(clk),.rst(rst),.cancel(cancel),
        .req_valid(state==ARENA_PREP),.req_ready(arena_ready),
        .arena_begin(arena_phase_q==0 ? tensor_begin_q : static_begin_q[arena_phase_q-3'd1]),
        .arena_end(arena_phase_q==0 ? tensor_end_q : static_end_q[arena_phase_q-3'd1]),
        // Static artifacts are readers: only the new image writers conflict.
        // Tensor is a writer and must also avoid every retained image reader.
        .frame_valid({(arena_phase_q==0 ? hvalid_q : 7'd0),wvalid_q}),.frame_base({hb_q,wb_q}),
        .frame_stride({hs_q,ws_q}),.frame_width({hw_q,ww_q}),
        .frame_height({hh_q,wh_q}),.busy(),.rsp_valid(arena_valid),.rsp_ready(1'b1),
        .error_code(arena_code),.error_index(arena_index)
    );
    always_comb begin
        left_id={group_q,1'b0};
        right_id=group_q==3 ? 3'd6 : left_id+3'd1;
        pair_present=hvalid_q[left_id]||hvalid_q[right_id];
        // An absent partner is replaced with the valid reader; read/read
        // aliasing is allowed by CHECK_PAIR_MASK, never a dummy address.
        if(!hvalid_q[left_id]) left_id=right_id;
        if(!hvalid_q[right_id]) right_id=left_id;
        bases={hb_q[right_id],hb_q[left_id],wb_q[writer_q]};
        strides={hs_q[right_id],hs_q[left_id],ws_q[writer_q]};
        widths={hw_q[right_id],hw_q[left_id],ww_q[writer_q]};
        heights={hh_q[right_id],hh_q[left_id],wh_q[writer_q]};
    end
    c1_frame_triple_layout_check #(.CHECK_PAIR_MASK(3'b011)) u_check (
        .clk(clk),.rst(rst),.cancel(cancel),.req_valid(check_req),.req_ready(check_ready),
        .frame_base(bases),.frame_stride(strides),.frame_width(widths),.frame_height(heights),
        .busy(),.rsp_valid(check_valid),.rsp_ready(1'b1),.error_code(check_code),.error_index()
    );
    always_ff @(posedge clk) begin
        if(rst||cancel) begin
            state<=IDLE;rsp_valid<=0;error_code<=0;error_address<=0;
            wvalid_q<=0;wb_q<='0;ws_q<='0;ww_q<='0;wh_q<='0;
            hvalid_q<=0;hb_q<='0;hs_q<='0;hw_q<='0;hh_q<='0;
            writer_q<=0;group_q<=0;
            arena_phase_q<=0;tensor_begin_q<=0;tensor_end_q<=0;static_begin_q<='0;static_end_q<='0;
        end else case(state)
            IDLE: if(req_valid) begin
                wvalid_q<=writer_valid;wb_q<=writer_base;ws_q<=writer_stride;
                ww_q<=writer_width;wh_q<=writer_height;
                hvalid_q<=held_valid;hb_q<=held_base;hs_q<=held_stride;
                hw_q<=held_width;hh_q<=held_height;
                tensor_begin_q<=tensor_begin;tensor_end_q<=tensor_end;
                static_begin_q<=static_begin;static_end_q<=static_end;
                arena_phase_q<=CHECK_TENSOR_ARENA ? 0 : 1;
                writer_q<=0;group_q<=0;state<=(CHECK_TENSOR_ARENA||CHECK_STATIC_ARENAS) ? ARENA_PREP : PREP;
            end
            ARENA_PREP: if(arena_ready) state<=ARENA_WAIT;
            ARENA_WAIT: if(arena_valid) begin
                if(arena_code!=0) begin
                    error_code<=arena_phase_q==0 ? (arena_code==3 ? 8'h37 : 8'h38) :
                                                  (arena_code==3 ? 8'h39 : 8'h3a);
                    error_address<=arena_index<2 ? wb_q[arena_index[0]] : hb_q[arena_index-4'd2];
                    rsp_valid<=1;state<=RESPONSE;
                end else if(CHECK_STATIC_ARENAS && arena_phase_q<4) begin
                    arena_phase_q<=arena_phase_q+1'b1;state<=ARENA_PREP;
                end else state<=PREP;
            end
            PREP: begin
                if(!wvalid_q[writer_q]||!pair_present) state<=NEXT_PAIR;
                else if(check_req&&check_ready) state<=WAIT_CHECK;
            end
            WAIT_CHECK: if(check_valid) begin
                if(check_code!=0) begin
                    error_code<=check_code==3 ? 8'h35 : 8'h36;
                    error_address<=wb_q[writer_q];rsp_valid<=1;state<=RESPONSE;
                end else state<=NEXT_PAIR;
            end
            NEXT_PAIR: begin
                if(group_q!=3) begin group_q<=group_q+1'b1;state<=PREP;end
                else if(!writer_q) begin writer_q<=1;group_q<=0;state<=PREP;end
                else begin rsp_valid<=1;state<=RESPONSE;end
            end
            RESPONSE: begin end
            default: state<=IDLE;
        endcase
    end
endmodule

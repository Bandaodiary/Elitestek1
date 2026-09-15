// C31 independent branch; C30 retained. Admit only phase-zero source SOFs.
// Phase advances on EVERY canonical SOF, even disabled/busy; enable is not reset.
// First source frame after coordinated reset has phase zero. No frame splicing.
// C30 independent two-pixel CDC ingress; retained C28/C29 sources unchanged.
`timescale 1ns/1ps
// Unstoppable, two-RGB-pixels/valid source -> checked fixed RGB ROI -> CDC ->
// backpressured ONE-pixel Resize source. cam_rgb={right_RGB,left_RGB}.
// FIFO_DEPTH and cam_peak count 49-bit pair records, NOT scalar pixels.
// Odd ROI x/width and single-pixel tails are supported; source width is even.
// NO RAW unpack/Debayer, variable ROI or CPU CSR.
// One capture job is in flight. Busy/disabled SOFs are skipped, never spliced.
// The last ROI pixel is withheld until the FULL source frame validates. Errors
// use a separate held status crossing, so a full pixel FIFO cannot lose cancel.
// Frame recovery drains pointers without resetting either clock domain.
// job_done is the actual downstream completion handshake AFTER AXI B drain.
// Coordinated cam_rst/rst is required, and both clocks must sample reset.
module c1_r2_camera_decimated_ingress #(
    parameter integer SOURCE_WIDTH=1920,SOURCE_HEIGHT=1080,
    parameter integer ROI_X=240,ROI_Y=0,ROI_WIDTH=1440,ROI_HEIGHT=1080,
    parameter integer FIFO_DEPTH=1024,FRAME_TIMEOUT=5000000,FRAME_DIVISOR=2,AW=$clog2(FIFO_DEPTH)
) (
    input wire cam_clk,cam_rst,cam_valid,cam_sof,cam_eol,cam_eof,cam_error,
    input wire [47:0] cam_rgb,
    output wire cam_busy,
    output logic [31:0] cam_seen,cam_skipped,
    output logic [AW:0] cam_peak,
    input wire clk,rst,enable,cancel,
    output wire job_valid,
    input wire job_ready,
    output logic [31:0] job_tag,
    input wire job_done,job_failed,
    output wire job_cancel,
    output wire s_valid,s_sof,s_eol,s_eof,
    input wire s_ready,
    output wire [23:0] s_rgb,
    output logic [15:0] s_x,s_y,
    output wire busy,config_error,
    output logic result_valid,result_failed,result_admitted,
    output logic [3:0] result_code,
    output logic [31:0] result_tag
);
    localparam GEOMETRY_OK=SOURCE_WIDTH>=2 && SOURCE_WIDTH<=65534 && SOURCE_WIDTH%2==0 && SOURCE_HEIGHT>=1 && SOURCE_HEIGHT<=65535 &&
        ROI_X>=0 && ROI_Y>=0 && ROI_WIDTH>=1 && ROI_WIDTH<=2048 && ROI_HEIGHT>=1 &&
        ROI_X+ROI_WIDTH<=SOURCE_WIDTH && ROI_Y+ROI_HEIGHT<=SOURCE_HEIGHT && FRAME_TIMEOUT>=2 && FRAME_DIVISOR>=1 && FRAME_DIVISOR<=256;
    localparam integer DW=FRAME_DIVISOR<=1 ? 1 : $clog2(FRAME_DIVISOR);
    logic [DW-1:0] frame_phase;
    localparam TW=$clog2(FRAME_TIMEOUT+1);
    logic request_q,ack_q;
    // Register core-domain controls BEFORE crossing. syn_keep prevents retiming
    // these flops away. This adds one core cycle, not an extra destination FF.
    (* syn_keep="true" *) logic enable_source_q,cancel_source_q;
    (* async_reg="true", syn_keep="true" *) logic ack_sync1,ack_sync2,req_sync1,req_sync2;
    (* async_reg="true", syn_keep="true" *) logic enable_sync1,enable_sync2,cancel_sync1,cancel_sync2;
    (* async_reg="true", syn_keep="true" *) logic done_sync1,done_sync2,bad_sync1,bad_sync2;
    logic source_active,source_done,source_bad,tail_valid,source_end;
    logic [3:0] source_code;
    logic [31:0] source_tag;
    logic [23:0] tail_rgb;
    logic [15:0] x_q,y_q;
    logic [TW-1:0] age_q;
    localparam [2:0] IDLE=0,ADMIT=1,STREAM=2,DRAIN=3;
    logic [2:0] state;
    logic owned,done_seen,failed_q,eof_sent,done_settled;
    logic [3:0] failed_code;
    wire source_cancel=(state!=IDLE) && (failed_q || cancel || (owned && job_done && job_failed));
    always_ff @(posedge clk)begin
        if(rst)begin enable_source_q<=0;cancel_source_q<=0;end
        else begin enable_source_q<=enable;cancel_source_q<=source_cancel;end
    end
    assign cam_busy=request_q!=ack_sync2;
    wire source_start=cam_valid && cam_sof && !cam_busy && enable_sync2 && !cancel_sync2 && GEOMETRY_OK && frame_phase==0;
    wire taking=(source_active || source_start) && cam_valid;
    wire [15:0] px=source_start ? 16'd0 : x_q;
    wire [15:0] py=source_start ? 16'd0 : y_q;
    wire last_source=px==SOURCE_WIDTH-2 && py==SOURCE_HEIGHT-1;
    wire raster_bad=cam_sof!=((px==0)&&(py==0)) || cam_eol!=(px==SOURCE_WIDTH-2) || cam_eof!=last_source;
    wire [15:0] px1=px+1'b1;
    wire inside0=px>=ROI_X && px<ROI_X+ROI_WIDTH && py>=ROI_Y && py<ROI_Y+ROI_HEIGHT;
    wire inside1=px1>=ROI_X && px1<ROI_X+ROI_WIDTH && py>=ROI_Y && py<ROI_Y+ROI_HEIGHT;
    wire last0=inside0 && px==ROI_X+ROI_WIDTH-1 && py==ROI_Y+ROI_HEIGHT-1;
    wire last1=inside1 && px1==ROI_X+ROI_WIDTH-1 && py==ROI_Y+ROI_HEIGHT-1;
    wire keep0=inside0 && !last0,keep1=inside1 && !last1;
    wire [48:0] pair_word={keep0 && keep1,(keep0 && keep1) ? cam_rgb[47:24] : 24'd0,
                          keep0 ? cam_rgb[23:0] : cam_rgb[47:24]};
    wire timed_out=cam_busy && !source_done && age_q==FRAME_TIMEOUT-1;
    wire abort_source=(cam_busy && !source_done && (cancel_sync2 || timed_out || cam_error)) ||
        (source_start && cam_error) || (taking && raster_bad);
    wire pixel_write=taking && !raster_bad && !cam_error && (keep0 || keep1) && !abort_source;
    wire tail_write=cam_busy && source_end && tail_valid && !source_done && !source_bad && !abort_source;
    wire fifo_in_ready,fifo_valid,fifo_empty;
    wire [48:0] fifo_rgb;
    logic high_pixel;
    wire [AW:0] fifo_level;
    wire fifo_pop;
    c1_r2_async_pixel_fifo_guarded #(.DATA_WIDTH(49),.DEPTH(FIFO_DEPTH)) u_fifo (
        .wr_clk(cam_clk),.wr_rst(cam_rst),.in_valid(pixel_write || tail_write),.in_ready(fifo_in_ready),
        .in_data(tail_write ? {25'd0,tail_rgb} : pair_word),.wr_level(fifo_level),
        .rd_clk(clk),.rd_rst(rst),.out_valid(fifo_valid),.out_ready(fifo_pop),.out_data(fifo_rgb),.rd_empty(fifo_empty));
    always_ff @(posedge cam_clk)begin
        if(cam_rst)begin
            frame_phase<=0;request_q<=0;ack_sync1<=0;ack_sync2<=0;enable_sync1<=0;enable_sync2<=0;cancel_sync1<=0;cancel_sync2<=0;
            source_active<=0;source_done<=0;source_bad<=0;source_code<=0;source_tag<=0;
            tail_valid<=0;source_end<=0;tail_rgb<=0;x_q<=0;y_q<=0;age_q<=0;cam_seen<=0;cam_skipped<=0;cam_peak<=0;
        end else begin
            ack_sync1<=ack_q;ack_sync2<=ack_sync1;enable_sync1<=enable_source_q;enable_sync2<=enable_sync1;
            cancel_sync1<=cancel_source_q;cancel_sync2<=cancel_sync1;
            if(cam_valid && cam_sof)begin
                frame_phase<=frame_phase==FRAME_DIVISOR-1 ? 0 : frame_phase+1'b1;
                cam_seen<=cam_seen+1;
                if(!source_start)cam_skipped<=cam_skipped+1;
            end
            if(cam_busy && !source_done)age_q<=age_q+1'b1;
            if(cam_busy && fifo_level>cam_peak)cam_peak<=fifo_level;
            if(source_start)begin
                request_q<=~request_q;source_tag<=cam_seen;source_active<=1;
                source_done<=0;source_bad<=0;source_code<=0;tail_valid<=0;source_end<=0;age_q<=0;
            end
            if(taking && !raster_bad && !cam_error)begin
                if(last_source)begin source_active<=0;source_end<=1;end
                if(px==SOURCE_WIDTH-2)begin x_q<=0;y_q<=py+1'b1;end
                else begin x_q<=px+16'd2;y_q<=py;end
                if(last0 || last1)begin tail_valid<=1;tail_rgb<=last0 ? cam_rgb[23:0] : cam_rgb[47:24];end
            end
            if(tail_write && fifo_in_ready)begin source_done<=1;tail_valid<=0;end
            if(abort_source || (pixel_write && !fifo_in_ready))begin
                source_active<=0;source_done<=1;source_bad<=1;tail_valid<=0;
                if(taking && raster_bad)source_code<=1;
                else if(pixel_write && !fifo_in_ready)source_code<=2;
                else if(timed_out)source_code<=3;
                else if(cam_error)source_code<=5;
                else source_code<=4;
            end
        end
    end
    assign config_error=!GEOMETRY_OK;
    assign busy=state!=IDLE || req_sync2!=ack_q;
    wire fail_now=bad_sync2 || cancel || (owned && job_done && job_failed);
    assign job_valid=!rst && state==ADMIT && !fail_now && !failed_q;
    assign job_cancel=!rst && owned && !done_seen && (fail_now || failed_q);
    assign s_valid=!rst && state==STREAM && !fail_now && !failed_q && !done_seen && fifo_valid;
    assign s_rgb=high_pixel ? fifo_rgb[47:24] : fifo_rgb[23:0];
    assign s_sof=s_x==0 && s_y==0;
    assign s_eol=s_x==ROI_WIDTH-1;
    assign s_eof=s_eol && s_y==ROI_HEIGHT-1;
    assign fifo_pop=!rst && ((state==DRAIN) || (s_valid && s_ready && (!fifo_rgb[48] || high_pixel)));
    always_ff @(posedge clk)begin
        if(rst || state==IDLE || state==DRAIN)high_pixel<=0;
        else if(s_valid && s_ready)high_pixel<=fifo_rgb[48] && !high_pixel;
    end
    always_ff @(posedge clk)begin
        if(rst)begin
            req_sync1<=0;req_sync2<=0;done_sync1<=0;done_sync2<=0;bad_sync1<=0;bad_sync2<=0;
            ack_q<=0;state<=IDLE;owned<=0;done_seen<=0;failed_q<=0;failed_code<=0;eof_sent<=0;done_settled<=0;
            job_tag<=0;s_x<=0;s_y<=0;result_valid<=0;result_failed<=0;result_admitted<=0;result_code<=0;result_tag<=0;
        end else begin
            req_sync1<=request_q;req_sync2<=req_sync1;done_sync1<=source_done;done_sync2<=done_sync1;
            bad_sync1<=source_bad;bad_sync2<=bad_sync1;result_valid<=0;
            if(state==IDLE)begin
                done_settled<=0;
                if(req_sync2!=ack_q)begin
                    state<=ADMIT;job_tag<=source_tag;owned<=0;done_seen<=0;failed_q<=0;failed_code<=0;eof_sent<=0;s_x<=0;s_y<=0;
                end
            end else begin
                done_settled<=done_sync2;
                if(fail_now)begin
                    failed_q<=1;state<=DRAIN;
                    if(!failed_q)failed_code<=bad_sync2 ? source_code : cancel ? 4'd4 : 4'd6;
                end
                if(job_valid && job_ready)begin owned<=1;state<=STREAM;end
                if(s_valid && s_ready)begin
                    if(s_eof)eof_sent<=1;
                    if(s_eol)begin s_x<=0;s_y<=s_y+1'b1;end
                    else s_x<=s_x+1'b1;
                end
                if(owned && job_done && !done_seen)begin
                    done_seen<=1;state<=DRAIN;
                    if(!job_failed && !failed_q && !fail_now && !eof_sent && !(s_valid && s_ready && s_eof))begin
                        failed_q<=1;failed_code<=6;
                    end
                end
                if(state==DRAIN && done_sync2 && done_settled && fifo_empty && (!owned || done_seen))begin
                    ack_q<=req_sync2;state<=IDLE;result_valid<=1;
                    result_failed<=failed_q || fail_now;result_admitted<=owned;result_tag<=job_tag;
                    result_code<=failed_q ? failed_code : fail_now ? (bad_sync2 ? source_code : cancel ? 4'd4 : 4'd6) : 4'd0;
                end
            end
        end
    end
`ifndef SYNTHESIS
    initial if(!GEOMETRY_OK)$fatal(1,"camera ingress invalid fixed geometry/timeout");
    always @(posedge clk)if(!rst)begin
        if(s_valid && eof_sent)$fatal(1,"camera ingress emitted pixels after ROI EOF");
        if(job_done && (!owned || done_seen))$fatal(1,"camera ingress unexpected downstream completion");
        if(state==IDLE && owned && !done_seen)$fatal(1,"camera ingress released live capture owner");
    end
`endif
endmodule



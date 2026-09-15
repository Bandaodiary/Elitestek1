`timescale 1ns/1ps
module tb_c1_raw_raster_guard #(parameter integer W=4,H=3);
    localparam integer XB=(W<=1)?1:$clog2(W),YB=(H<=1)?1:$clog2(H);
    logic clk=0,rst=1,cancel=0,start_valid=0,s_valid=0,m_ready=0;
    wire start_ready,busy,done,error,s_ready,m_valid;
    wire [3:0] error_code;
    logic [9:0] s_raw10=0;
    logic [XB-1:0] s_x=0;
    logic [YB-1:0] s_y=0;
    logic s_sof=0,s_eol=0,s_eof=0;
    wire [9:0] m_raw10;
    wire [XB-1:0] m_x;
    wire [YB-1:0] m_y;
    wire m_sof,m_eol,m_eof;
    integer received=0,frames=0,faults=0,c;
    always #5 clk=~clk;
    c1_raw_raster_guard #(.FRAME_WIDTH(W),.FRAME_HEIGHT(H)) dut(.*);
    c1_rv_hold_checker #(.WIDTH(13+XB+YB)) held (
        .clk(clk),.rst(rst),.cancel(cancel),.valid(m_valid),.ready(m_ready),
        .payload({m_raw10,m_x,m_y,m_sof,m_eol,m_eof})
    );
    always @(posedge clk) if(!rst && !cancel && m_valid && m_ready) begin
        if(m_raw10!==10'(received*17+5) || m_x!==XB'(received%W) || m_y!==YB'(received/W) ||
           m_sof!==(received==0) || m_eol!==((received%W)==W-1) || m_eof!==(received==W*H-1))
            $fatal(1,"guard output mismatch pixel=%0d",received);
        received++;
    end
    task automatic launch;
        @(negedge clk);
        if(!start_ready) $fatal(1,"guard not restartable");
        received=0;start_valid=1;
        @(negedge clk);start_valid=0;
    endtask
    task automatic drive(input integer k, bad);
        @(negedge clk);s_valid=1;m_ready=0;
        s_raw10=10'(k*17+5);s_x=XB'(k%W);s_y=YB'(k/W);
        s_sof=(k==0);s_eol=(k%W==W-1);s_eof=(k==W*H-1);
        case(bad)
            1:s_x=s_x^1'b1;
            2:s_y=s_y^1'b1;
            3:s_sof=0;
            4:s_sof=1;
            5:s_eol=~s_eol;
            6:s_eof=~s_eof;
            7:s_eof=0;
            8:s_eol=0;
        endcase
        if(bad) begin
            #1;
            if(m_valid || !s_ready) $fatal(1,"malformed token leaked or waited on sink");
            @(negedge clk);s_valid=0;
            if(!error || done || !busy || start_ready || s_ready || m_valid)
                $fatal(1,"malformed frame was not fenced");
            if(error_code!==(bad<=2 ? 4'd1 : bad<=4 ? 4'd2 : (bad==5 || bad==8) ? 4'd3 : 4'd4))
                $fatal(1,"wrong guard error code");
        end else begin
            repeat(3) begin
                @(negedge clk);
                if(done || error || s_ready || !m_valid) $fatal(1,"guard failed backpressure");
            end
            m_ready=1;
            @(negedge clk);s_valid=0;m_ready=0;
        end
    endtask
    task automatic good_frame;
        launch();
        for(integer k=0;k<W*H;k++) drive(k,0);
        if(received!=W*H || !done || busy || !start_ready) $fatal(1,"good frame completion failed");
        frames++;
    endtask
    initial begin
        repeat(4) @(negedge clk);rst=0;
        good_frame();
        for(c=1;c<=8;c++) begin
            if(c==4 && W*H==1) continue;
            launch();
            for(integer k=0;k<((c==4 || c>=7)?W*H-1:0);k++) drive(k,0);
            drive((c==4 || c>=7)?W*H-1:0,c);
            repeat(4) @(negedge clk);
            if(!error || !busy || start_ready || done) $fatal(1,"fault fence did not persist");
            cancel=1;
            @(negedge clk);cancel=0;
            faults++;
            good_frame();
        end
        launch();
        @(negedge clk);s_valid=1;m_ready=0;s_x=0;s_y=0;s_raw10=5;
        s_sof=1;s_eol=(W==1);s_eof=(W*H==1);
        repeat(3) @(negedge clk);
        if(!m_valid || s_ready) $fatal(1,"cancel fixture was not stalled");
        cancel=1;m_ready=1;
        #1;
        if(m_valid || s_ready || start_ready) $fatal(1,"cancel failed immediate handshake fence");
        @(negedge clk);cancel=0;s_valid=0;m_ready=0;
        if(done || error || busy || received) $fatal(1,"cancel accepted or completed a discarded beat");
        good_frame();
        $display("C1_RAW_RASTER_GUARD_PASS width=%0d height=%0d frames=%0d faults=%0d",W,H,frames,faults);
        $finish;
    end
    initial begin #1000000;$fatal(1,"raster guard timeout");end
endmodule

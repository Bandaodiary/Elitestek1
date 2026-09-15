`timescale 1ns/1ps
module tb_c1_column_line_cache_c8 #(
    parameter integer ROWS = 3,
    parameter integer CAPACITY = 13,
    parameter bit READ_ON_LOOKUP = 0,
    parameter bit RESPONSE_BYPASS = 0,
    parameter bit REUSE_ROW_MAP = 0
);
    logic clk=0, rst=1;
    always #5 clk=~clk;
    logic group_start_valid=0;
    wire group_start_ready, group_start_done, group_start_error, config_valid;
    logic [15:0] frame_width=0, frame_height=0;
    logic [3:0] frame_groups=0;
    wire [2:0] group_start_error_code;
    logic abort_req=0, flush_req=0;
    wire abort_done, flush_done;
    logic column_valid=0, column_rsp_ready=0;
    wire column_ready, column_rsp_valid, column_rsp_error;
    logic signed [16:0] column_x=0, column_y=0;
    logic [2:0] column_group=0;
    wire [191:0] column_rsp_data_s8;
    wire refill_req_valid, refill_req_ready, refill_word_ready;
    wire [15:0] refill_req_row, refill_req_word_count;
    logic refill_word_valid=0, refill_word_last=0, refill_word_error=0;
    logic [63:0] refill_word_data_s8=0;
    wire cache_error, busy, quiescent;
    wire [2:0] cache_error_code;
    c1_column_line_cache_c8 #(.LINE_ROWS(ROWS), .MAX_ROW_WORDS(CAPACITY),
        .READ_ON_LOOKUP(READ_ON_LOOKUP), .RESPONSE_BYPASS(RESPONSE_BYPASS),
        .REUSE_ROW_MAP(REUSE_ROW_MAP)) dut(.*);

    integer cycles=0, accepted=0, responses=0, refill_requests=0, refill_beats=0;
    integer aborts=0, flushes=0, three_bank_reads=0, one_bank_reads=0, two_bank_reads=0;
    integer req_stalls=0, rsp_stalls=0, source_gaps=0;
    integer row_map_hits=0;
    integer source_row=0, source_count=0, source_index=0, source_mode=0, source_epoch=0;
    integer model_epoch=1, fault_mode=0;
    integer configured_w=0, configured_h=0, configured_g=0;
    integer requested_rows[0:2047];
    logic source_active=0, allow_request=1, pause_source=0;
    logic expected_req_error=0, pending=0, pending_error=0;
    logic [191:0] pending_column;
    logic [31:0] rng=32'hace12467;

    // Row and word number are deliberately distinguishable in EVERY C8 byte.
    // This is an independent memory oracle, not a peek into cache RAM/tags.
    function automatic [63:0] memory_word(input integer row, word_index, epoch);
        for (integer c=0;c<8;c++)
            memory_word[c*8 +: 8] = 8'((row*37) ^ (row>>8) ^
                (word_index*19) ^ (word_index>>5) ^ (c*29) ^ (epoch*71));
    endfunction
    function automatic integer clamp_int(input integer c, size);
        if(c<0) clamp_int=0;
        else if(c>=size) clamp_int=size-1;
        else clamp_int=c;
    endfunction
    function automatic [191:0] oracle_column(input integer x,y,g);
        for(integer r=0;r<3;r++)
            oracle_column[r*64 +: 64] = memory_word(clamp_int(y+r-1,configured_h),
                clamp_int(x,configured_w)*configured_g+g,model_epoch);
    endfunction
    assign refill_req_ready = !rst && allow_request && !source_active &&
                              !refill_word_valid && cycles%3!=0;
    // Independent single-flight source: a presented word remains stable until
    // accepted; gaps and request stalls are unrelated to the DUT's row hits.
    always @(posedge clk) begin
        if(rst) begin
            cycles<=0; source_active<=0; refill_word_valid<=0;
        end else begin
            cycles<=cycles+1;
            if(refill_req_valid && !refill_req_ready) req_stalls++;
            if(refill_word_ready && !refill_word_valid) source_gaps++;
            if(refill_req_valid && refill_req_ready) begin
                if(refill_req_word_count!=configured_w*configured_g ||
                    refill_req_row>=configured_h || source_active)
                    $fatal(1,"invalid refill request row/count/ownership");
                requested_rows[refill_requests]=refill_req_row;
                refill_requests++;
                source_row<=refill_req_row; source_count<=refill_req_word_count;
                source_index<=0; source_mode<=fault_mode; source_epoch<=model_epoch;
                source_active<=1;
            end
            if(refill_word_valid && refill_word_ready) begin
                refill_beats++;
                refill_word_valid<=0;
                if(source_index==source_count) source_active<=0;
            end
            if(source_active && (!refill_word_valid || refill_word_ready)) begin
                if(source_index<source_count && !pause_source && cycles%4!=0) begin
                    refill_word_valid<=1;
                    refill_word_data_s8<=memory_word(source_row,source_index,source_epoch);
                    refill_word_last<= (source_mode==1 && source_index==1) ||
                        (source_index==source_count-1 && source_mode!=2);
                    refill_word_error<= (source_mode==3 && source_index==2);
                    source_index<=source_index+1;
                end else refill_word_valid<=0;
            end
        end
    end
    always @(posedge clk) begin : scoreboard
        integer ports;
        if(!rst) begin
            if(group_start_valid && group_start_ready) begin
                configured_w=frame_width; configured_h=frame_height; configured_g=frame_groups;
                if(pending) $fatal(1,"configuration overtook an accepted column");
            end
            if(column_valid && column_ready) begin
                if(pending) $fatal(1,"multiple columns accepted without retirement");
                pending=1; accepted++;
                pending_error=expected_req_error || column_group>=configured_g;
                pending_column=oracle_column($signed(column_x),$signed(column_y),column_group);
            end
            if(column_rsp_valid) begin
                if(!pending || column_rsp_error!==pending_error)
                    $fatal(1,"column response ownership/error mismatch got=%b expected=%b",column_rsp_error,pending_error);
                if(column_rsp_data_s8 !== (pending_error ? 192'b0 : pending_column))
                    $fatal(1,"column data mismatch got=%h expected=%h",column_rsp_data_s8,pending_column);
                if(column_rsp_ready) begin pending=0; responses++; end
                else rsp_stalls++;
            end
            if(abort_done) begin
                aborts++;
                if(pending || source_active || refill_word_valid || config_valid)
                    $fatal(1,"abort completed before column/refill retirement");
            end
            if(flush_done) begin
                flushes++;
                if(pending || source_active || refill_word_valid)
                    $fatal(1,"flush completed before column/refill retirement");
            end
            ports=0;
            if(dut.reuse_row_fire) row_map_hits++;
            for(integer b=0;b<ROWS;b++) if(dut.rd_en[b]) ports++;
            if(ports==3) three_bank_reads++;
            if(ports==2) two_bank_reads++;
            if(ports==1) one_bank_reads++;
        end
    end

    task automatic configure(input integer w,h,g,code=0);
        begin
            @(negedge clk);
            frame_width=w; frame_height=h; frame_groups=g; group_start_valid=1;
            do @(posedge clk); while(!group_start_ready);
            #1;
            if(!group_start_done || group_start_error !== (code!=0) ||
                group_start_error_code!=code || config_valid !== (code==0))
                $fatal(1,"configuration completion mismatch w=%0d h=%0d g=%0d code=%0d",w,h,g,code);
            @(negedge clk); group_start_valid=0;
        end
    endtask
    task automatic issue(input integer x,y,g,err=0);
        begin
            @(negedge clk);
            column_x=x; column_y=y; column_group=g;
            column_valid=1; expected_req_error=(err!=0);
            do @(posedge clk); while(!column_ready);
            #1;
            @(negedge clk);
            column_valid=0;
            // Producer no longer owns the transaction: these inputs change
            // immediately, including during the first missing-row lookup.
            column_x=-65536; column_y=65535; column_group=7;
        end
    endtask
    task automatic collect(input integer hold_cycles=3, fence=0);
        begin
            while(!column_rsp_valid) @(negedge clk);
            if(fence) group_start_valid=1;
            repeat(hold_cycles) begin
                @(posedge clk); #1;
                if(!column_rsp_valid || column_ready || group_start_ready)
                    $fatal(1,"held response/config fence violated");
            end
            @(negedge clk); group_start_valid=0; column_rsp_ready=1;
            @(posedge clk); #1;
            @(negedge clk); column_rsp_ready=0;
            if(pending || accepted!=responses) $fatal(1,"column did not retire exactly once");
        end
    endtask
    task automatic request_column(input integer x,y,g,req_delta=-1);
        integer before_req;
        begin
            before_req=refill_requests;
            issue(x,y,g); collect(3,1);
            if(req_delta>=0 && refill_requests-before_req!=req_delta)
                $fatal(1,"refill count mismatch got=%0d expected=%0d y=%0d",refill_requests-before_req,req_delta,y);
        end
    endtask
    task automatic idle_flush;
        integer before_done;
        begin
            before_done=flushes;
            @(negedge clk); flush_req=1;
            while(flushes==before_done) @(negedge clk);
            @(negedge clk); flush_req=0;
            @(negedge clk);
            if(!config_valid || cache_error || dut.row_valid_q!='0)
                $fatal(1,"flush failed to preserve config/clear tags/error");
        end
    endtask
    task automatic measure_hit_stream;
        integer previous_cycle, before_req, before_rsp;
        begin
            configure(5,7,2);
            request_column(0,1,0,3);
            before_req=refill_requests; before_rsp=responses;
            previous_cycle=0;
            @(negedge clk);
            column_x=3; column_y=1; column_group=1;
            expected_req_error=0; column_valid=1; column_rsp_ready=1;
            // Saturate both directions, unlike the deliberately stalled
            // functional tests. Check ACTUAL handshake spacing, not RAM width.
            for(integer n=0;n<12;n++) begin
                do @(posedge clk); while(!column_ready);
                #1;
                if(n!=0 && cycles-previous_cycle!=((REUSE_ROW_MAP?3:5-int'(READ_ON_LOOKUP))-int'(RESPONSE_BYPASS)))
                    $fatal(1,"column cache hit initiation interval mismatch got=%0d",cycles-previous_cycle);
                previous_cycle=cycles;
                // Sustain the interface rate with DIFFERENT addresses/data,
                // not repeated reads of one word that could hide stale RAM Q.
                @(negedge clk);
                column_x=n%5;column_group=n%2;
            end
            @(negedge clk); column_valid=0;
            while(pending) @(negedge clk);
            column_rsp_ready=0;
            if(refill_requests!=before_req || responses-before_rsp!=12)
                $fatal(1,"hit stream refilled or lost a response");
            $display("C1_COLUMN_CACHE_HIT_RATE_PASS columns=12 initiation_interval=%0d words_per_column=3",(REUSE_ROW_MAP?3:5-int'(READ_ON_LOOKUP))-int'(RESPONSE_BYPASS));
        end
    endtask
    task automatic row_map_contract;
        integer before_hits, before_done;
        begin
            for(integer groups=1;groups<=8;groups++) begin
                configure(CAPACITY/groups,3,groups);
                request_column(0,1,0,3);
                before_hits=row_map_hits;
                // Exercise the last legal group/address, including an
                // irregular capacity: acceptance must use the NEW offset.
                request_column(CAPACITY/groups-1,1,groups-1,0);
                if(row_map_hits-before_hits!=int'(REUSE_ROW_MAP))
                    $fatal(1,"row-map full-range address/group path mismatch");
            end
            configure(5,7,2);
            request_column(0,0,0,2);
            before_hits=row_map_hits;
            request_column(4,0,1,0);
            if(row_map_hits-before_hits!=int'(REUSE_ROW_MAP))
                $fatal(1,"same-row x/group change did not use expected path");
            before_hits=row_map_hits;
            request_column(4,-1,1,0);
            if(row_map_hits!=before_hits) $fatal(1,"clamped center aliased distinct border lanes");
            request_column(-65536,-1,0,0);
            request_column(65535,-1,1,0);
            before_hits=row_map_hits;
            issue(1,-1,7,1); collect(4);
            request_column(2,-1,1,0);
            if(row_map_hits!=before_hits) $fatal(1,"invalid group preserved row-map eligibility");
            idle_flush(); model_epoch++;
            before_hits=row_map_hits;
            request_column(2,-1,1,1);
            if(row_map_hits!=before_hits) $fatal(1,"flush reused stale row data");
            // Same Y but new geometry and new backing content cannot reuse.
            configure(3,7,1); model_epoch++;
            before_hits=row_map_hits;
            request_column(2,-1,0,1);
            if(row_map_hits!=before_hits) $fatal(1,"configuration reused previous bank map");
            // A fence already asserted BEFORE acceptance suppresses RAM read
            // and request acceptance, even if the previous row map is warm.
            @(negedge clk); before_done=flushes;
            flush_req=1;column_valid=1;column_x=1;column_y=-1;column_group=0;
            #1;
            if(column_ready || dut.rd_en!='0) $fatal(1,"fence failed to block warm-map admission");
            @(negedge clk);column_valid=0;
            while(flushes==before_done) @(negedge clk);
            @(negedge clk);flush_req=0;model_epoch++;
            request_column(1,-1,0,1);
            $display("C1_COLUMN_ROW_MAP_CONTRACT_PASS enabled=%0d address_group=1 signed_border=1 invalid_group=1 reconfigure=1 flush=1 admission_fence=1 groups=1:8",REUSE_ROW_MAP);
        end
    endtask
    task automatic row_map_capture_fence(input integer kind);
        integer before_hits,before_a,before_f,guard;
        begin
            configure(5,7,2); request_column(0,3,0,3);
            before_hits=row_map_hits;before_a=aborts;before_f=flushes;
            issue(4,3,1);
            if(row_map_hits!=before_hits+1 || dut.state_q!=dut.ST_CAPTURE)
                $fatal(1,"missed actual row-map acceptance/read edge");
            // With bypass the result is ALREADY visible and must be preserved;
            // with registered capture it is not yet offered and is poisoned.
            pending_error=!RESPONSE_BYPASS;
            abort_req=(kind!=2);flush_req=(kind!=1);
            collect(5);
            guard=0;
            while((kind!=2 && aborts==before_a) || (kind!=1 && flushes==before_f)) begin
                @(negedge clk);guard++;
                if(guard>50) $fatal(1,"row-map capture fence did not drain");
            end
            repeat(3) @(negedge clk);
            if(column_ready || group_start_ready || dut.row_map_valid_q)
                $fatal(1,"row-map held fence admitted work or retained ownership");
            abort_req=0;flush_req=0;model_epoch++;
            @(negedge clk);
            if(kind!=2) configure(5,7,2);
            before_hits=row_map_hits;
            request_column(4,3,1,3);
            if(row_map_hits!=before_hits) $fatal(1,"row-map restart reused pre-fence contents");
            $display("C1_COLUMN_ROW_MAP_FENCE_PASS kind=%0d visible_before_fence=%0d held=5 reset=0",kind,RESPONSE_BYPASS);
        end
    endtask
    task automatic fault_case(input integer mode);
        integer before_beats, before_req;
        begin
            configure(5,7,2);
            before_beats=refill_beats; before_req=refill_requests;
            fault_mode=mode;
            issue(2,3,1,1); collect(7,1);
            fault_mode=0;
            if(refill_beats-before_beats!=10 || refill_requests-before_req!=1 ||
                !cache_error || cache_error_code!=(mode==3?1:2) || dut.row_valid_q!='0)
                $fatal(1,"fault did not drain exactly one poisoned refill");
            @(negedge clk); column_valid=1;
            repeat(4) begin @(posedge clk); #1;
                if(column_ready) $fatal(1,"sticky cache fault accepted new work");
            end
            @(negedge clk); column_valid=0;
            idle_flush();
            request_column(2,3,1,3);
            $display("C1_COLUMN_CACHE_FAULT_PASS mode=%0d declared_drain=10 restart=1",mode);
        end
    endtask
    task automatic bypass_retire_fence(input integer kind);
        integer before_a,before_f,guard;
        begin
            configure(5,7,2);
            before_a=aborts;before_f=flushes;
            issue(2,3,1);
            guard=0;
            while(!column_rsp_valid) begin
                @(negedge clk);guard++;
                if(guard>1000) $fatal(1,"bypass immediate fence response timeout");
            end
            if(dut.state_q!=dut.ST_CAPTURE) $fatal(1,"test missed real capture bypass");
            // Present a late fence and READY within the first visible cycle.
            // Neither may rewrite success; the direct-retire state shortcut
            // must still wait a later cycle to acknowledge maintenance.
            abort_req=(kind!=2);flush_req=(kind!=1);column_rsp_ready=1;
            #1;
            if(!column_rsp_valid || column_rsp_error || column_rsp_data_s8!==pending_column)
                $fatal(1,"late fence poisoned immediately consumed bypass");
            @(posedge clk);#1;
            if(pending || aborts!=before_a || flushes!=before_f || abort_done || flush_done)
                $fatal(1,"bypass maintenance ack overtook response retirement");
            @(negedge clk);column_rsp_ready=0;guard=0;
            while((kind!=2 && aborts==before_a) || (kind!=1 && flushes==before_f)) begin
                @(negedge clk);guard++;
                if(guard>50) $fatal(1,"bypass maintenance did not finish");
            end
            repeat(4) begin
                @(negedge clk);
                if(column_ready || group_start_ready || aborts-before_a!=(kind!=2) || flushes-before_f!=(kind!=1))
                    $fatal(1,"bypass held maintenance admitted work/retriggered");
            end
            abort_req=0;flush_req=0;model_epoch++;
            @(negedge clk);
            if(kind!=2) configure(5,7,2);
            request_column(2,3,1,3);
            $display("C1_COLUMN_CACHE_BYPASS_RETIRE_FENCE_PASS kind=%0d capture_handshake=1 preserved_success=1 reset=0",kind);
        end
    endtask

    task automatic cancel_case(input integer phase,kind,mode=0);
        integer before_aborts, before_flushes, before_beats, before_reqs, consumed_before;
        begin
            configure(5,7,2);
            before_aborts=aborts; before_flushes=flushes;
            before_beats=refill_beats; before_reqs=refill_requests;
            fault_mode=mode;
            allow_request=(phase!=1); pause_source=(phase==2);
            // Bypass makes capture an already-presented response. A late
            // fence at that phase must preserve success, just as phase 5.
            issue(2,3,1,!(phase==5 || (phase==4 && RESPONSE_BYPASS)));
            case(phase)
                0: begin end // accepted, but no refill request offered yet
                1: while(!refill_req_valid) @(negedge clk);
                2: begin
                    while(!refill_word_ready) @(negedge clk);
                    pause_source=0;
                    while(refill_beats-before_beats<2) @(negedge clk);
                    pause_source=1;
                end
                // The optimized path issues RAM enables during all-hit
                // lookup; fence that edge, not the now-skipped ST_READ.
                3: while(READ_ON_LOOKUP ? !(dut.state_q==dut.ST_LOOKUP && dut.all_hit) :
                         dut.state_q!=dut.ST_READ) @(negedge clk);
                4: while(dut.state_q!=dut.ST_CAPTURE) @(negedge clk);
                5: while(!column_rsp_valid) @(negedge clk);
            endcase
            abort_req=(kind!=2); flush_req=(kind==2);
            // Kind 3 adds flush after abort was already latched. Both must
            // complete only after the same transaction and response drain.
            repeat(3) begin
                @(posedge clk); #1;
                if(abort_done || flush_done || group_start_ready || column_ready)
                    $fatal(1,"maintenance completed/admitted work too early phase=%0d",phase);
                if(phase==1 && (!refill_req_valid || refill_req_row!=2 || refill_req_word_count!=10))
                    $fatal(1,"offered refill withdrawn during cancellation");
            end
            @(negedge clk);
            if(kind==3) flush_req=1;
            // A second edge of an already pending kind coalesces; it must not
            // create a second completion after the eventual response drain.
            if(kind==1) abort_req=0;
            if(kind==2) flush_req=0;
            @(negedge clk);
            if(kind==1) abort_req=1;
            if(kind==2) flush_req=1;
            allow_request=1; pause_source=0;
            while(!column_rsp_valid) @(negedge clk);
            if(mode!=0 && (!cache_error || cache_error_code!=(mode==3?1:2)))
                $fatal(1,"cancelled fault lost its diagnostic before maintenance completion");
            consumed_before=responses;
            repeat(5) begin
                @(posedge clk); #1;
                if(aborts!=before_aborts || flushes!=before_flushes ||
                    !config_valid || responses!=consumed_before)
                    $fatal(1,"maintenance failed held-response fence");
            end
            collect(2,1);
            while((kind!=2 && aborts==before_aborts) ||
                  (kind!=1 && flushes==before_flushes)) @(negedge clk);
            repeat(5) begin
                @(posedge clk); #1;
                if(column_ready || group_start_ready ||
                    aborts-before_aborts!=(kind!=2) || flushes-before_flushes!=(kind!=1))
                    $fatal(1,"held maintenance retriggered/admitted work");
            end
            if(dut.row_valid_q!='0 || cache_error || config_valid!==(kind==2))
                $fatal(1,"maintenance did not clear tags/status as specified");
            if(phase==0 && refill_requests!=before_reqs)
                $fatal(1,"cancel before refill still issued a request");
            if((phase==1 || phase==2) &&
                (refill_requests-before_reqs!=1 || refill_beats-before_beats!=10))
                $fatal(1,"cancelled refill failed exact-count drain");
            @(negedge clk); abort_req=0; flush_req=0;
            fault_mode=0;
            @(negedge clk);
            // Alter the memory oracle to ensure stale pre-maintenance row
            // contents cannot satisfy the restart, even without global reset.
            model_epoch++;
            if(kind!=2) configure(5,7,2);
            request_column(2,3,1,3);
            $display("C1_COLUMN_CACHE_CANCEL_PASS phase=%0d kind=%0d restart=1 reset=0 fault=%0d",phase,kind,mode);
        end
    endtask

    initial begin : stimulus
        integer before_req, three_before, one_before;
        repeat(3) @(negedge clk);
        rst=0;
        configure(0,7,2,1);
        configure(5,0,2,1);
        configure(5,7,0,1);
        configure(1,7,9,2);
        configure(CAPACITY+1,7,1,3);
        configure(65535,7,8,3); // wide product must not wrap into a valid row
        configure(5,7,2);
        request_column(2,1,0,3);
        request_column(4,1,1,0); // all groups present in each cached row
        request_column(3,2,1,1);
        // For ROWS=3 the round-robin victim initially points to a needed row;
        // filling missing row 0 must preserve row 1 and choose another bank.
        request_column(-1,0,0,ROWS==3?1:0);
        request_column(2,1,1,ROWS==3?1:0);
        for(integer n=0;n<80;n++) begin
            rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
            request_column(int'(rng[7:0])%11-3,int'(rng[15:8])%12-3,rng[16]);
        end
        before_req=refill_requests;
        issue(1,1,7,1); collect(4,1);
        if(cache_error || refill_requests!=before_req) $fatal(1,"invalid group touched refill/cache fault");

        configure(1,1,1);
        one_before=one_bank_reads;
        request_column(-65536,-65536,0,1);
        request_column(65535,65535,0,0);
        if(one_bank_reads-one_before!=2) $fatal(1,"duplicate boundary rows were not one-bank reads");
        configure(1,65535,8);
        request_column(65535,65535,7,1);
        request_column(-65536,-65536,0,1);
        request_column(0,65534,3,1);

        // Exercise the final legal address of a full row, including 1280-word
        // production-sized banks and a non-power-of-two 13-word bank.
        configure(CAPACITY,3,1);
        three_before=three_bank_reads;
        request_column(CAPACITY-1,1,0,3);
        if(three_bank_reads-three_before!=1) $fatal(1,"column was not a simultaneous three-bank read");
        request_column(CAPACITY,1,0,0);
        for(integer mode=1;mode<=3;mode++) fault_case(mode);
        row_map_contract();
        if(REUSE_ROW_MAP)
            for(integer kind=1;kind<=3;kind++) row_map_capture_fence(kind);
        for(integer phase=0;phase<=5;phase++)
            for(integer kind=1;kind<=3;kind++) cancel_case(phase,kind);
        for(integer mode=1;mode<=3;mode++) cancel_case(2,3,mode);
        if(RESPONSE_BYPASS)
            for(integer kind=1;kind<=3;kind++) bypass_retire_fence(kind);
        measure_hit_stream();
        if(accepted!=responses || pending || source_active || !quiescent ||
            three_bank_reads==0 || two_bank_reads==0 || one_bank_reads==0 ||
            req_stalls==0 || rsp_stalls==0 || source_gaps==0)
            $fatal(1,"column cache final coverage/ownership mismatch");
        $display("C1_COLUMN_CACHE_PASS rows=%0d capacity=%0d columns=%0d refills=%0d words=%0d parallel3=%0d parallel2=%0d single=%0d req_stalls=%0d rsp_stalls=%0d gaps=%0d",
            ROWS,CAPACITY,responses,refill_requests,refill_beats,three_bank_reads,
            two_bank_reads,one_bank_reads,req_stalls,rsp_stalls,source_gaps);
        $finish;
    end
    initial begin #20000000; $fatal(1,"column cache timeout state=%0d accepted=%0d responses=%0d",dut.state_q,accepted,responses); end
endmodule

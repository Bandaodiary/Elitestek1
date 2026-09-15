`timescale 1ns/1ps
// Generated semantic DW16/PW8 pairing, paired with execution_plan.sv.
module c1_r2_row_fusion_plan (input wire [4:0] index,
    output logic enable, output logic [4:0] pw_parameter_block,
    output logic [15:0] pw_parameter_beats, output logic [1:0] pw_dst_slot);
    always_comb begin
        enable=0;pw_parameter_block=0;pw_parameter_beats=0;pw_dst_slot=0;
        case(index)
            5'd14:begin enable=1;pw_parameter_block=5'd15;pw_parameter_beats=16'd24;pw_dst_slot=2'd2;end
            default:begin end
        endcase
    end
endmodule

// CSI-2 RAW10 payload helper. Byte 0 is packed[7:0], byte 4 is packed[39:32].
// Vendor CSI wrappers may use this module when their IP exposes packet bytes
// instead of already-unpacked samples.
`timescale 1ns/1ps

module c1_raw10_unpack4 (
    input  logic [39:0] in_packed40,
    output logic [9:0]  pixel0,
    output logic [9:0]  pixel1,
    output logic [9:0]  pixel2,
    output logic [9:0]  pixel3
);
    always_comb begin
        pixel0 = {in_packed40[7:0],   in_packed40[33:32]};
        pixel1 = {in_packed40[15:8],  in_packed40[35:34]};
        pixel2 = {in_packed40[23:16], in_packed40[37:36]};
        pixel3 = {in_packed40[31:24], in_packed40[39:38]};
    end
endmodule

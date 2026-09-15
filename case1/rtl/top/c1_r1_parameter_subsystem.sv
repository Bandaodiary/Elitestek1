// Atomic DDR-to-local parameter path with an abort fence compatible with an
// outer transaction-locking AXI arbiter.
module c1_r1_parameter_subsystem #(
    parameter integer ARENA_BYTES = 16896,
    parameter integer PARAM_ADDR_W = 11
) (
    input  logic                       clk,
    input  logic                       rst,
    input  logic                       start_valid,
    output logic                       start_ready,
    input  logic [31:0]                base_addr,
    input  logic                       abort_request,
    output logic                       abort_pending,
    output logic                       busy,
    output logic                       done,
    output logic                       error,
    output logic                       aborted,
    output logic [3:0]                 error_code,
    output logic [31:0]                error_address,
    output logic                       active_valid,
    output logic                       active_bank,
    output logic [31:0]                generation,
    input  logic                       engine_rd_en,
    input  logic [PARAM_ADDR_W-1:0]    engine_rd_addr,
    output logic                       engine_rd_valid,
    output logic                       engine_rd_error,
    output logic [127:0]               engine_rd_data,
    output logic [31:0]                m_axi_araddr,
    output logic [7:0]                 m_axi_arlen,
    output logic [2:0]                 m_axi_arsize,
    output logic [1:0]                 m_axi_arburst,
    output logic                       m_axi_arvalid,
    input  logic                       m_axi_arready,
    input  logic [127:0]               m_axi_rdata,
    input  logic [1:0]                 m_axi_rresp,
    input  logic                       m_axi_rlast,
    input  logic                       m_axi_rvalid,
    output logic                       m_axi_rready
);

    logic abort_to_loader;
    logic bank_load_start;
    logic bank_load_start_ready;
    logic bank_load_valid;
    logic bank_load_ready;
    logic [127:0] bank_load_data;
    logic bank_load_last;
    logic bank_load_abort;
    logic bank_load_busy;
    logic bank_load_done;
    logic bank_load_aborted;
    logic bank_load_error;
    logic [2:0] bank_load_error_code;

    c1_axi_read_abort_fence u_abort_fence (
        .clk(clk),
        .rst(rst),
        .abort_request(abort_request),
        .leaf_arvalid(m_axi_arvalid),
        .leaf_arready(m_axi_arready),
        .abort_pending(abort_pending),
        .abort_to_leaf(abort_to_loader)
    );

    c1_axi_parameter_loader #(
        .ARENA_BYTES(ARENA_BYTES)
    ) u_loader (
        .clk(clk),
        .rst(rst),
        .start_valid(start_valid),
        .start_ready(start_ready),
        .start_base_addr(base_addr),
        .abort(abort_to_loader),
        .busy(busy),
        .done(done),
        .error(error),
        .aborted(aborted),
        .error_code(error_code),
        .error_address(error_address),
        .bank_load_start(bank_load_start),
        .bank_load_start_ready(bank_load_start_ready),
        .bank_load_valid(bank_load_valid),
        .bank_load_ready(bank_load_ready),
        .bank_load_data(bank_load_data),
        .bank_load_last(bank_load_last),
        .bank_load_abort(bank_load_abort),
        .bank_load_busy(bank_load_busy),
        .bank_load_done(bank_load_done),
        .bank_load_aborted(bank_load_aborted),
        .bank_load_error(bank_load_error),
        .m_axi_araddr(m_axi_araddr),
        .m_axi_arlen(m_axi_arlen),
        .m_axi_arsize(m_axi_arsize),
        .m_axi_arburst(m_axi_arburst),
        .m_axi_arvalid(m_axi_arvalid),
        .m_axi_arready(m_axi_arready),
        .m_axi_rdata(m_axi_rdata),
        .m_axi_rresp(m_axi_rresp),
        .m_axi_rlast(m_axi_rlast),
        .m_axi_rvalid(m_axi_rvalid),
        .m_axi_rready(m_axi_rready)
    );

    c1_r1_parameter_bank #(
        .ARENA_BYTES(ARENA_BYTES),
        .READ_PORTS(1),
        .ADDR_W(PARAM_ADDR_W)
    ) u_bank (
        .clk(clk),
        .rst(rst),
        .load_start(bank_load_start),
        .load_start_ready(bank_load_start_ready),
        .load_valid(bank_load_valid),
        .load_ready(bank_load_ready),
        .load_data(bank_load_data),
        .load_last(bank_load_last),
        .load_abort(bank_load_abort),
        .load_busy(bank_load_busy),
        .load_done(bank_load_done),
        .load_aborted(bank_load_aborted),
        .load_error(bank_load_error),
        .load_error_code(bank_load_error_code),
        .active_valid(active_valid),
        .active_bank(active_bank),
        .generation(generation),
        .rd_en(engine_rd_en),
        .rd_addr(engine_rd_addr),
        .rd_valid(engine_rd_valid),
        .rd_error(engine_rd_error),
        .rd_data(engine_rd_data)
    );

endmodule

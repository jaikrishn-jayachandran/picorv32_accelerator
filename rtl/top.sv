`include "axi/typedef.svh"

// ---------------------------------------------------------------------------
// PicoRV32 + AXI4-Lite crossbar + RAM + FFT accelerator SoC
//
// Master 0 : PicoRV32 (AXI4-Lite)
// Master 1 : iDMA (tied off in this top level)
//
// Slave 0  : System RAM + debug window (0x0000_0000 .. 0x0000_FFFF)
// Slave 1  : iDMA control window (not populated, answers with DECERR)
// Slave 2  : FFT accelerator control (0x3000_0000 .. 0x3000_0FFF)
//
// Any other CPU access (e.g. the 0x2000_0000 UART debug writes) is routed to
// slave 0 by the crossbar default port so the testbench can observe them.
// ---------------------------------------------------------------------------
module top (
    input  logic clk_i,
    input  logic rst_ni,
    // External FFT AXI-Stream input
    input  logic [31:0] fft_s_axis_tdata,
    input  logic        fft_s_axis_tvalid,
    output logic        fft_s_axis_tready,
    input  logic        fft_s_axis_tlast,

    // External FFT AXI-Stream output
    output logic [31:0] fft_m_axis_tdata,
    output logic        fft_m_axis_tvalid,
    input  logic        fft_m_axis_tready,
    output logic        fft_m_axis_tlast
);

    // -----------------------------------------------------------------------
    // AXI4-Lite channel/request/response types
    // -----------------------------------------------------------------------
    typedef logic [31:0] addr_t;
    typedef logic [31:0] data_t;
    typedef logic [ 3:0] strb_t;

    `AXI_LITE_TYPEDEF_ALL(axi_lite, addr_t, data_t, strb_t)

    localparam int unsigned NumMasters = 2;
    localparam int unsigned NumSlaves  = 3;

    localparam int unsigned RamSlv  = 0;
    localparam int unsigned IdmaSlv = 1;
    localparam int unsigned FftSlv  = 2;

    // -----------------------------------------------------------------------
    // Crossbar configuration
    // -----------------------------------------------------------------------
    localparam axi_pkg::xbar_cfg_t XbarCfg = '{
        NoSlvPorts:         NumMasters,
        NoMstPorts:         NumSlaves,
        MaxMstTrans:        4,
        MaxSlvTrans:        4,
        FallThrough:        1'b0,
        LatencyMode:        axi_pkg::NO_LATENCY,
        PipelineStages:     0,
        AxiIdWidthSlvPorts: 1,
        AxiIdUsedSlvPorts:  1,
        UniqueIds:          1'b0,
        AxiAddrWidth:       32,
        AxiDataWidth:       32,
        NoAddrRules:        2
    };

    // RAM is selected at 0x0000_0000, FFT at 0x3000_0000.
    axi_pkg::xbar_rule_32_t [1:0] addr_map;
    assign addr_map[0] = '{idx: RamSlv, start_addr: 32'h0000_0000, end_addr: 32'h0001_0000};
    assign addr_map[1] = '{idx: FftSlv, start_addr: 32'h3000_0000, end_addr: 32'h3000_1000};

    // Only the CPU (slave port 0) uses the default port -> RAM/debug window.
    logic [NumMasters-1:0] en_default_mst;
    logic [NumMasters-1:0][$clog2(NumSlaves)-1:0] default_mst;
    assign en_default_mst = 2'b01;
    assign default_mst    = '0;

    // -----------------------------------------------------------------------
    // Crossbar wiring
    // -----------------------------------------------------------------------
    wire axi_lite_req_t  [NumMasters-1:0] slv_reqs;
    wire axi_lite_resp_t [NumMasters-1:0] slv_resps;
    wire axi_lite_req_t  [NumSlaves-1:0]  mst_reqs;
    wire axi_lite_resp_t [NumSlaves-1:0]  mst_resps;

    // -----------------------------------------------------------------------
    // Master 0: PicoRV32
    // -----------------------------------------------------------------------
    picorv32_axi #(
        .ENABLE_COUNTERS     (1),
        .ENABLE_REGS_DUALPORT(1),
        .COMPRESSED_ISA      (1),
        .ENABLE_MUL          (1),
        .ENABLE_DIV          (1),
        .STACKADDR           (32'h0000_8000)
    ) i_cpu (
        .clk             (clk_i),
        .resetn          (rst_ni),
        .trap            (),

        .mem_axi_awvalid (slv_reqs[0].aw_valid),
        .mem_axi_awready (slv_resps[0].aw_ready),
        .mem_axi_awaddr  (slv_reqs[0].aw.addr),
        .mem_axi_awprot  (slv_reqs[0].aw.prot),

        .mem_axi_wvalid  (slv_reqs[0].w_valid),
        .mem_axi_wready  (slv_resps[0].w_ready),
        .mem_axi_wdata   (slv_reqs[0].w.data),
        .mem_axi_wstrb   (slv_reqs[0].w.strb),

        .mem_axi_bvalid  (slv_resps[0].b_valid),
        .mem_axi_bready  (slv_reqs[0].b_ready),

        .mem_axi_arvalid (slv_reqs[0].ar_valid),
        .mem_axi_arready (slv_resps[0].ar_ready),
        .mem_axi_araddr  (slv_reqs[0].ar.addr),
        .mem_axi_arprot  (slv_reqs[0].ar.prot),

        .mem_axi_rvalid  (slv_resps[0].r_valid),
        .mem_axi_rready  (slv_reqs[0].r_ready),
        .mem_axi_rdata   (slv_resps[0].r.data),

        .pcpi_valid      (),
        .pcpi_insn       (),
        .pcpi_rs1        (),
        .pcpi_rs2        (),
        .pcpi_wr         (1'b0),
        .pcpi_rd         (32'h0),
        .pcpi_wait       (1'b0),
        .pcpi_ready      (1'b0),

        .irq             (32'h0),
        .eoi             (),

        .trace_valid     (),
        .trace_data      ()
    );

    // -----------------------------------------------------------------------
    // Master 1: iDMA.  The standalone iDMA backend is not wired into this
    // SoC yet, so the master port is kept idle.
    // -----------------------------------------------------------------------
    assign slv_reqs[1] = '0;

    // -----------------------------------------------------------------------
    // AXI4-Lite crossbar
    // -----------------------------------------------------------------------
    axi_lite_xbar #(
        .Cfg        (XbarCfg),
        .aw_chan_t  (axi_lite_aw_chan_t),
        .w_chan_t   (axi_lite_w_chan_t),
        .b_chan_t   (axi_lite_b_chan_t),
        .ar_chan_t  (axi_lite_ar_chan_t),
        .r_chan_t   (axi_lite_r_chan_t),
        .axi_req_t  (axi_lite_req_t),
        .axi_resp_t (axi_lite_resp_t),
        .rule_t     (axi_pkg::xbar_rule_32_t)
    ) i_xbar (
        .clk_i                (clk_i),
        .rst_ni               (rst_ni),
        .slv_ports_req_i      (slv_reqs),
        .slv_ports_resp_o     (slv_resps),
        .mst_ports_req_o      (mst_reqs),
        .mst_ports_resp_i     (mst_resps),
        .addr_map_i           (addr_map),
        .en_default_mst_port_i(en_default_mst),
        .default_mst_port_i   (default_mst)
    );

    // -----------------------------------------------------------------------
    // Slave 0: system RAM + debug window
    //
    // The RAM itself only covers 64 KiB.  Addresses outside that range (for
    // example the 0x2000_0000 UART debug writes) are still visible on the
    // i_system_ram ports for the testbench, but they do not modify memory.
    // -----------------------------------------------------------------------
    logic        ram_awready, ram_wready, ram_bvalid;
    logic        ram_arready, ram_rvalid;
    logic        ram_req, ram_we;
    logic [31:0] ram_addr, ram_wdata, ram_rdata;
    logic [ 3:0] ram_wstrb;

    typedef enum logic {W_IDLE, W_RESP} w_state_t;
    typedef enum logic [1:0] {R_IDLE, R_REQ, R_RESP} r_state_t;

    w_state_t w_state;
    r_state_t r_state;

    logic        aw_captured, w_captured;
    logic [31:0] awaddr_q, wdata_q;
    logic [ 3:0] wstrb_q;
    logic [31:0] araddr_q;

    assign ram_awready = (w_state == W_IDLE) && !aw_captured && (r_state == R_IDLE);
    assign ram_wready  = (w_state == W_IDLE) && !w_captured  && (r_state == R_IDLE);
    assign ram_arready = (r_state == R_IDLE) && (w_state == W_IDLE) &&
                         !aw_captured && !w_captured;

    // A write is committed as soon as both the address and data are available.
    logic wr_fire;
    assign wr_fire = (w_state == W_IDLE) &&
                     (aw_captured || (mst_reqs[RamSlv].aw_valid && ram_awready)) &&
                     (w_captured  || (mst_reqs[RamSlv].w_valid  && ram_wready));

    assign ram_req   = wr_fire || (r_state == R_REQ);
    assign ram_we    = wr_fire;
    assign ram_addr  = wr_fire ? (aw_captured ? awaddr_q : mst_reqs[RamSlv].aw.addr)
                               : araddr_q;
    assign ram_wdata = w_captured ? wdata_q : mst_reqs[RamSlv].w.data;
    assign ram_wstrb = w_captured ? wstrb_q : mst_reqs[RamSlv].w.strb;

    assign mst_resps[RamSlv].aw_ready = ram_awready;
    assign mst_resps[RamSlv].w_ready  = ram_wready;
    assign mst_resps[RamSlv].b_valid  = (w_state == W_RESP);
    assign mst_resps[RamSlv].b.resp   = axi_pkg::RESP_OKAY;
    assign mst_resps[RamSlv].ar_ready = ram_arready;
    assign mst_resps[RamSlv].r_valid  = (r_state == R_RESP);
    assign mst_resps[RamSlv].r.data   = ram_rdata;
    assign mst_resps[RamSlv].r.resp   = axi_pkg::RESP_OKAY;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            w_state     <= W_IDLE;
            r_state     <= R_IDLE;
            aw_captured <= 1'b0;
            w_captured  <= 1'b0;
            awaddr_q    <= '0;
            wdata_q     <= '0;
            wstrb_q     <= '0;
            araddr_q    <= '0;
        end else begin
            case (w_state)
                W_IDLE: begin
                    if (mst_reqs[RamSlv].aw_valid && ram_awready) begin
                        awaddr_q    <= mst_reqs[RamSlv].aw.addr;
                        aw_captured <= 1'b1;
                    end
                    if (mst_reqs[RamSlv].w_valid && ram_wready) begin
                        wdata_q    <= mst_reqs[RamSlv].w.data;
                        wstrb_q    <= mst_reqs[RamSlv].w.strb;
                        w_captured <= 1'b1;
                    end
                    if (wr_fire) begin
                        aw_captured <= 1'b0;
                        w_captured  <= 1'b0;
                        w_state     <= W_RESP;
                    end
                end
                W_RESP: begin
                    if (mst_reqs[RamSlv].b_ready) w_state <= W_IDLE;
                end
                default: w_state <= W_IDLE;
            endcase

            case (r_state)
                R_IDLE: begin
                    if (mst_reqs[RamSlv].ar_valid && ram_arready) begin
                        araddr_q <= mst_reqs[RamSlv].ar.addr;
                        r_state  <= R_REQ;
                    end
                end
                R_REQ: r_state <= R_RESP;
                R_RESP: if (mst_reqs[RamSlv].r_ready) r_state <= R_IDLE;
                default: r_state <= R_IDLE;
            endcase
        end
    end

    soc_ram i_system_ram (
        .clk_i  (clk_i),
        .rst_ni (rst_ni),
        .req_i  (ram_req),
        .we_i   (ram_we),
        .addr_i (ram_addr),
        .wdata_i(ram_wdata),
        .wstrb_i(ram_wstrb),
        .rdata_o(ram_rdata)
    );

    // -----------------------------------------------------------------------
    // Slave 1: iDMA control window.  Not populated in this top level; it
    // terminates any transaction with a DECERR response.
    // -----------------------------------------------------------------------
    logic slv1_aw_seen, slv1_w_seen, slv1_bvalid, slv1_rvalid;

    assign mst_resps[IdmaSlv].aw_ready = !slv1_bvalid && !slv1_aw_seen;
    assign mst_resps[IdmaSlv].w_ready  = !slv1_bvalid && !slv1_w_seen;
    assign mst_resps[IdmaSlv].b_valid  = slv1_bvalid;
    assign mst_resps[IdmaSlv].b.resp   = axi_pkg::RESP_DECERR;
    assign mst_resps[IdmaSlv].ar_ready = !slv1_rvalid;
    assign mst_resps[IdmaSlv].r_valid  = slv1_rvalid;
    assign mst_resps[IdmaSlv].r.data   = '0;
    assign mst_resps[IdmaSlv].r.resp   = axi_pkg::RESP_DECERR;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            slv1_aw_seen <= 1'b0;
            slv1_w_seen  <= 1'b0;
            slv1_bvalid  <= 1'b0;
            slv1_rvalid  <= 1'b0;
        end else begin
            if (mst_reqs[IdmaSlv].aw_valid && mst_resps[IdmaSlv].aw_ready)
                slv1_aw_seen <= 1'b1;
            if (mst_reqs[IdmaSlv].w_valid && mst_resps[IdmaSlv].w_ready)
                slv1_w_seen <= 1'b1;

            if (slv1_aw_seen && slv1_w_seen) begin
                slv1_aw_seen <= 1'b0;
                slv1_w_seen  <= 1'b0;
                slv1_bvalid  <= 1'b1;
            end else if (slv1_bvalid && mst_reqs[IdmaSlv].b_ready) begin
                slv1_bvalid <= 1'b0;
            end

            if (mst_reqs[IdmaSlv].ar_valid && mst_resps[IdmaSlv].ar_ready)
                slv1_rvalid <= 1'b1;
            else if (slv1_rvalid && mst_reqs[IdmaSlv].r_ready)
                slv1_rvalid <= 1'b0;
        end
    end

    // -----------------------------------------------------------------------
    // Slave 2: FFT accelerator
    //
    // The data path is fed by the iDMA master in the full system.  While the
    // iDMA is idle the stream input is tied low and the output is drained.
    // -----------------------------------------------------------------------
    fft_analysis #(
        .DATA_W(32),
        .MAX_N (256)
    ) i_fft_accelerator (
        .clk_i  (clk_i),
        .rst_ni (rst_ni),

        .s_axil_awaddr (mst_reqs[FftSlv].aw.addr),
        .s_axil_awvalid(mst_reqs[FftSlv].aw_valid),
        .s_axil_awready(mst_resps[FftSlv].aw_ready),

        .s_axil_wdata  (mst_reqs[FftSlv].w.data),
        .s_axil_wstrb  (mst_reqs[FftSlv].w.strb),
        .s_axil_wvalid (mst_reqs[FftSlv].w_valid),
        .s_axil_wready (mst_resps[FftSlv].w_ready),

        .s_axil_bresp  (mst_resps[FftSlv].b.resp),
        .s_axil_bvalid (mst_resps[FftSlv].b_valid),
        .s_axil_bready (mst_reqs[FftSlv].b_ready),

        .s_axil_araddr (mst_reqs[FftSlv].ar.addr),
        .s_axil_arvalid(mst_reqs[FftSlv].ar_valid),
        .s_axil_arready(mst_resps[FftSlv].ar_ready),

        .s_axil_rdata  (mst_resps[FftSlv].r.data),
        .s_axil_rresp  (mst_resps[FftSlv].r.resp),
        .s_axil_rvalid (mst_resps[FftSlv].r_valid),
        .s_axil_rready (mst_reqs[FftSlv].r_ready),

        .s_axis_tdata  (fft_s_axis_tdata),
        .s_axis_tvalid (fft_s_axis_tvalid),
        .s_axis_tready (fft_s_axis_tready),
        .s_axis_tlast  (fft_s_axis_tlast),

        .m_axis_tdata  (fft_m_axis_tdata),
        .m_axis_tvalid (fft_m_axis_tvalid),
        .m_axis_tready (fft_m_axis_tready),
        .m_axis_tlast  (fft_m_axis_tlast)
    );

endmodule


// ---------------------------------------------------------------------------
// System RAM wrapper.
//
// Keeps a 32-bit AXI address view (so the testbench can see debug writes at
// 0x2000_0000) while only the lower 64 KiB are backed by the real memory.
// ---------------------------------------------------------------------------
module soc_ram #(
    parameter int unsigned ADDR_WIDTH = 16,
    parameter int unsigned DATA_WIDTH = 32
) (
    input  logic                    clk_i,
    input  logic                    rst_ni,
    input  logic                    req_i,
    input  logic                    we_i,
    input  logic [31:0]             addr_i,
    input  logic [DATA_WIDTH-1:0]   wdata_i,
    input  logic [DATA_WIDTH/8-1:0] wstrb_i,
    output logic [DATA_WIDTH-1:0]   rdata_o
);

    localparam logic [31:0] RAM_LIMIT = 32'h0001_0000;

    logic                   ram_req;
    logic                   ram_we;
    logic [ADDR_WIDTH-1:0]  ram_addr;

    assign ram_req  = req_i && (addr_i < RAM_LIMIT);
    assign ram_we   = we_i  && (addr_i < RAM_LIMIT);
    assign ram_addr = addr_i[ADDR_WIDTH-1:0];

    ram #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH)
    ) i_ram (
        .clk_i  (clk_i),
        .rst_ni (rst_ni),
        .req_i  (ram_req),
        .we_i   (ram_we),
        .addr_i (ram_addr),
        .wdata_i(wdata_i),
        .wstrb_i(wstrb_i),
        .rdata_o(rdata_o)
    );

endmodule

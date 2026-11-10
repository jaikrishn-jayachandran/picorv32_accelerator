
module fft_analysis #(
    parameter int DATA_W = 32,
    parameter int MAX_N  = 256
)(
    input  logic                  clk_i,
    input  logic                  rst_ni,

    // AXI4-Lite slave
    input  logic [DATA_W-1:0]     s_axil_awaddr,
    input  logic                  s_axil_awvalid,
    output logic                  s_axil_awready,

    input  logic [DATA_W-1:0]     s_axil_wdata,
    input  logic [3:0]            s_axil_wstrb,
    input  logic                  s_axil_wvalid,
    output logic                  s_axil_wready,

    output logic [1:0]            s_axil_bresp,
    output logic                  s_axil_bvalid,
    input  logic                  s_axil_bready,

    input  logic [DATA_W-1:0]     s_axil_araddr,
    input  logic                  s_axil_arvalid,
    output logic                  s_axil_arready,

    output logic [DATA_W-1:0]     s_axil_rdata,
    output logic [1:0]            s_axil_rresp,
    output logic                  s_axil_rvalid,
    input  logic                  s_axil_rready,

    // AXI4-Stream input: real-valued samples
    input  logic [DATA_W-1:0]     s_axis_tdata,
    input  logic                  s_axis_tvalid,
    output logic                  s_axis_tready,
    input  logic                  s_axis_tlast,

    // AXI4-Stream output: real, imaginary, real, imaginary...
    output logic [DATA_W-1:0]     m_axis_tdata,
    output logic                  m_axis_tvalid,
    input  logic                  m_axis_tready,
    output logic                  m_axis_tlast
);

    localparam int PTR_W = $clog2(MAX_N);

    typedef enum logic [1:0] {
        IDLE,
        COLLECT,
        COMPUTE,
        STREAM_OUT
    } state_t;

    state_t state;

    // ------------------------------------------------------------
    // AXI-Lite registers
    // ------------------------------------------------------------

    logic [31:0] reg_ctrl;
    logic [31:0] reg_fft_n;
    logic done_reg;

    logic aw_pending;
    logic w_pending;
    logic bvalid_reg;

    logic [31:0] awaddr_reg;
    logic [31:0] wdata_reg;

    logic ar_pending;
    logic rvalid_reg;

    logic [31:0] araddr_reg;

    assign s_axil_awready = !aw_pending && !bvalid_reg;
    assign s_axil_wready  = !w_pending  && !bvalid_reg;

    assign s_axil_bvalid = bvalid_reg;
    assign s_axil_bresp  = 2'b00;

    assign s_axil_arready = !ar_pending && !rvalid_reg;
    assign s_axil_rvalid  = rvalid_reg;
    assign s_axil_rresp   = 2'b00;

    wire busy = (state != IDLE);

    // Bit 0 = BUSY
    // Bit 1 = DONE
    wire [31:0] reg_status = {30'b0, done_reg, busy};

    // ------------------------------------------------------------
    // FFT storage and counters
    // ------------------------------------------------------------

    logic signed [31:0] real_mem [0:MAX_N-1];
    logic signed [31:0] imag_mem [0:MAX_N-1];

    logic [PTR_W-1:0] input_count;
    logic [PTR_W-1:0] output_count;

    // Must have PTR_W+1 bits to represent MAX_N itself.
    logic [PTR_W:0] fft_n;

    logic output_imag;

    logic [PTR_W:0] stage_span;
    logic [PTR_W:0] half_span;
    logic [PTR_W:0] group_base;
    logic [PTR_W:0] butterfly_j;

    logic [PTR_W-1:0] stage;

    logic [PTR_W:0] idx_a;
    logic [PTR_W:0] idx_b;
    logic [PTR_W:0] twiddle_index;

    logic signed [31:0] a_real;
    logic signed [31:0] a_imag;
    logic signed [31:0] b_real;
    logic signed [31:0] b_imag;

    logic signed [15:0] tw_re;
    logic signed [15:0] tw_im;

    logic signed [63:0] mult_rr;
    logic signed [63:0] mult_ii;
    logic signed [63:0] mult_ri;
    logic signed [63:0] mult_ir;

    logic signed [63:0] product_real;
    logic signed [63:0] product_imag;

    logic signed [31:0] t_real;
    logic signed [31:0] t_imag;

    // ------------------------------------------------------------
    // Bit reversal
    // ------------------------------------------------------------

    function automatic logic [PTR_W-1:0] reverse_bits(
        input logic [PTR_W-1:0] value,
        input integer width
    );
        integer k;
        begin
            reverse_bits = '0;

            for (k = 0; k < PTR_W; k = k + 1) begin
                if (k < width)
                    reverse_bits[width-1-k] = value[k];
            end
        end
    endfunction

    // ------------------------------------------------------------
    // 256-point Q1.15 twiddle ROM
    //
    // W[k] = cos(2*pi*k/256) - j*sin(2*pi*k/256)
    //
    // The upper half is generated using quarter-wave symmetry.
    // This initial block is suitable for simulation. For ASIC
    // synthesis, use a technology-supported ROM implementation.
    // ------------------------------------------------------------

    logic signed [15:0] twiddle_re [0:128];
    logic signed [15:0] twiddle_im [0:128];

    integer ti;

    initial begin

        for (ti = 0; ti <= 128; ti = ti + 1) begin
            twiddle_re[ti] = 16'sd0;
            twiddle_im[ti] = 16'sd0;
        end

        twiddle_re[0]  = 16'sd32767;
        twiddle_im[0]  = 16'sd0;

        twiddle_re[1]  = 16'sd32757; twiddle_im[1]  = -16'sd804;
        twiddle_re[2]  = 16'sd32728; twiddle_im[2]  = -16'sd1608;
        twiddle_re[3]  = 16'sd32678; twiddle_im[3]  = -16'sd2410;
        twiddle_re[4]  = 16'sd32610; twiddle_im[4]  = -16'sd3212;
        twiddle_re[5]  = 16'sd32522; twiddle_im[5]  = -16'sd4011;
        twiddle_re[6]  = 16'sd32413; twiddle_im[6]  = -16'sd4808;
        twiddle_re[7]  = 16'sd32286; twiddle_im[7]  = -16'sd5602;
        twiddle_re[8]  = 16'sd32137; twiddle_im[8]  = -16'sd6393;
        twiddle_re[9]  = 16'sd31969; twiddle_im[9]  = -16'sd7179;
        twiddle_re[10] = 16'sd31779; twiddle_im[10] = -16'sd7962;
        twiddle_re[11] = 16'sd31570; twiddle_im[11] = -16'sd8739;
        twiddle_re[12] = 16'sd31340; twiddle_im[12] = -16'sd9512;
        twiddle_re[13] = 16'sd31090; twiddle_im[13] = -16'sd10278;
        twiddle_re[14] = 16'sd30820; twiddle_im[14] = -16'sd11039;
        twiddle_re[15] = 16'sd30530; twiddle_im[15] = -16'sd11793;
        twiddle_re[16] = 16'sd30221; twiddle_im[16] = -16'sd12539;
        twiddle_re[17] = 16'sd29892; twiddle_im[17] = -16'sd13279;
        twiddle_re[18] = 16'sd29543; twiddle_im[18] = -16'sd14010;
        twiddle_re[19] = 16'sd29177; twiddle_im[19] = -16'sd14732;
        twiddle_re[20] = 16'sd28790; twiddle_im[20] = -16'sd15446;
        twiddle_re[21] = 16'sd28385; twiddle_im[21] = -16'sd16151;
        twiddle_re[22] = 16'sd27961; twiddle_im[22] = -16'sd16846;
        twiddle_re[23] = 16'sd27518; twiddle_im[23] = -16'sd17531;
        twiddle_re[24] = 16'sd27058; twiddle_im[24] = -16'sd18205;
        twiddle_re[25] = 16'sd26580; twiddle_im[25] = -16'sd18868;
        twiddle_re[26] = 16'sd26084; twiddle_im[26] = -16'sd19520;
        twiddle_re[27] = 16'sd25571; twiddle_im[27] = -16'sd20160;
        twiddle_re[28] = 16'sd25041; twiddle_im[28] = -16'sd20787;
        twiddle_re[29] = 16'sd24494; twiddle_im[29] = -16'sd21402;
        twiddle_re[30] = 16'sd23931; twiddle_im[30] = -16'sd22004;
        twiddle_re[31] = 16'sd23352; twiddle_im[31] = -16'sd22593;
        twiddle_re[32] = 16'sd22757; twiddle_im[32] = -16'sd23170;
        twiddle_re[33] = 16'sd22147; twiddle_im[33] = -16'sd23732;
        twiddle_re[34] = 16'sd21522; twiddle_im[34] = -16'sd24279;
        twiddle_re[35] = 16'sd20883; twiddle_im[35] = -16'sd24812;
        twiddle_re[36] = 16'sd20229; twiddle_im[36] = -16'sd25330;
        twiddle_re[37] = 16'sd19562; twiddle_im[37] = -16'sd25832;
        twiddle_re[38] = 16'sd18881; twiddle_im[38] = -16'sd26318;
        twiddle_re[39] = 16'sd18187; twiddle_im[39] = -16'sd26788;
        twiddle_re[40] = 16'sd17480; twiddle_im[40] = -16'sd27242;
        twiddle_re[41] = 16'sd16762; twiddle_im[41] = -16'sd27679;
        twiddle_re[42] = 16'sd16031; twiddle_im[42] = -16'sd28099;
        twiddle_re[43] = 16'sd15290; twiddle_im[43] = -16'sd28502;
        twiddle_re[44] = 16'sd14537; twiddle_im[44] = -16'sd28887;
        twiddle_re[45] = 16'sd13774; twiddle_im[45] = -16'sd29254;
        twiddle_re[46] = 16'sd13001; twiddle_im[46] = -16'sd29604;
        twiddle_re[47] = 16'sd12218; twiddle_im[47] = -16'sd29935;
        twiddle_re[48] = 16'sd11426; twiddle_im[48] = -16'sd30247;
        twiddle_re[49] = 16'sd10625; twiddle_im[49] = -16'sd30541;
        twiddle_re[50] = 16'sd9816;  twiddle_im[50] = -16'sd30816;
        twiddle_re[51] = 16'sd8999;  twiddle_im[51] = -16'sd31072;
        twiddle_re[52] = 16'sd8174;  twiddle_im[52] = -16'sd31309;
        twiddle_re[53] = 16'sd7342;  twiddle_im[53] = -16'sd31526;
        twiddle_re[54] = 16'sd6503;  twiddle_im[54] = -16'sd31724;
        twiddle_re[55] = 16'sd5658;  twiddle_im[55] = -16'sd31902;
        twiddle_re[56] = 16'sd4808;  twiddle_im[56] = -16'sd32060;
        twiddle_re[57] = 16'sd3951;  twiddle_im[57] = -16'sd32198;
        twiddle_re[58] = 16'sd3090;  twiddle_im[58] = -16'sd32316;
        twiddle_re[59] = 16'sd2224;  twiddle_im[59] = -16'sd32413;
        twiddle_re[60] = 16'sd1354;  twiddle_im[60] = -16'sd32490;
        twiddle_re[61] = 16'sd480;   twiddle_im[61] = -16'sd32547;
        twiddle_re[62] = -16'sd393;  twiddle_im[62] = -16'sd32583;
        twiddle_re[63] = -16'sd1265; twiddle_im[63] = -16'sd32598;
        twiddle_re[64] = 16'sd0;     twiddle_im[64] = -16'sd32767;

        // Correct quarter-wave symmetry for indices 65..128.
        for (ti = 65; ti <= 128; ti = ti + 1) begin
            twiddle_re[ti] = -twiddle_im[128-ti];
            twiddle_im[ti] = -twiddle_re[128-ti];
        end
    end

    // ------------------------------------------------------------
    // Butterfly arithmetic
    // ------------------------------------------------------------

    always_comb begin

        idx_a = group_base + butterfly_j;
        idx_b = idx_a + half_span;

        // Use the configured FFT length, not MAX_N.
        if (stage_span != 0)
            twiddle_index = butterfly_j * (fft_n / stage_span);
        else
            twiddle_index = '0;

        a_real = real_mem[idx_a[PTR_W-1:0]];
        a_imag = imag_mem[idx_a[PTR_W-1:0]];

        b_real = real_mem[idx_b[PTR_W-1:0]];
        b_imag = imag_mem[idx_b[PTR_W-1:0]];

        tw_re = twiddle_re[twiddle_index[PTR_W-1:0]];
        tw_im = twiddle_im[twiddle_index[PTR_W-1:0]];

        mult_rr = b_real * tw_re;
        mult_ii = b_imag * tw_im;

        mult_ri = b_real * tw_im;
        mult_ir = b_imag * tw_re;

        product_real = (mult_rr - mult_ii) >>> 15;
        product_imag = (mult_ri + mult_ir) >>> 15;

        t_real = product_real[31:0];
        t_imag = product_imag[31:0];

        m_axis_tvalid = (state == STREAM_OUT);

        if (output_imag)
            m_axis_tdata = imag_mem[output_count];
        else
            m_axis_tdata = real_mem[output_count];

        m_axis_tlast =
            (output_count == fft_n - 1'b1) && output_imag;
    end

    assign s_axis_tready = (state == COLLECT);

    // ------------------------------------------------------------
    // FFT state machine
    // ------------------------------------------------------------

    integer i;

    always_ff @(posedge clk_i or negedge rst_ni) begin

        if (!rst_ni) begin

            state        <= IDLE;

            input_count  <= '0;
            output_count <= '0;
            output_imag  <= 1'b0;

            fft_n        <= 64;

            stage        <= '0;
            stage_span   <= 2;
            half_span    <= 1;
            group_base   <= '0;
            butterfly_j <= '0;

            done_reg     <= 1'b0;

            for (i = 0; i < MAX_N; i = i + 1) begin
                real_mem[i] <= '0;
                imag_mem[i] <= '0;
            end

        end else begin

            case (state)

                IDLE: begin

                    input_count  <= '0;
                    output_count <= '0;
                    output_imag  <= 1'b0;

                    if (reg_ctrl[0]) begin

                        done_reg <= 1'b0;

                        if ((reg_fft_n >= 2) &&
                            (reg_fft_n <= MAX_N) &&
                            ((reg_fft_n & (reg_fft_n - 1)) == 0)) begin

                            fft_n <= reg_fft_n[PTR_W:0];

                            stage        <= '0;
                            stage_span   <= 2;
                            half_span    <= 1;
                            group_base   <= '0;
                            butterfly_j <= '0;

                            state <= COLLECT;
                        end
                    end
                end

                

                COLLECT: begin

                    if (s_axis_tvalid && s_axis_tready) begin

                        real_mem[
                            reverse_bits(input_count, $clog2(fft_n))
                        ] <= $signed(s_axis_tdata);

                        imag_mem[
                            reverse_bits(input_count, $clog2(fft_n))
                        ] <= 32'sd0;

                        if (input_count == fft_n - 1'b1) begin

                            input_count  <= '0;

                            stage        <= '0;
                            stage_span   <= 2;
                            half_span    <= 1;
                            group_base   <= '0;
                            butterfly_j <= '0;

                            state <= COMPUTE;

                        end else begin

                            input_count <= input_count + 1'b1;

                        end
                    end
                end

                

                COMPUTE: begin

                    real_mem[idx_a[PTR_W-1:0]] <= a_real + t_real;
                    imag_mem[idx_a[PTR_W-1:0]] <= a_imag + t_imag;

                    real_mem[idx_b[PTR_W-1:0]] <= a_real - t_real;
                    imag_mem[idx_b[PTR_W-1:0]] <= a_imag - t_imag;

                    if (butterfly_j == half_span - 1'b1) begin

                        butterfly_j <= '0;

                        if (group_base + stage_span >= fft_n) begin

                            group_base <= '0;

                            if (stage_span == fft_n) begin

                                output_count <= '0;
                                output_imag  <= 1'b0;

                                state <= STREAM_OUT;

                            end else begin

                                stage      <= stage + 1'b1;
                                stage_span <= stage_span << 1;
                                half_span  <= half_span << 1;

                            end

                        end else begin

                            group_base <= group_base + stage_span;

                        end

                    end else begin

                        butterfly_j <= butterfly_j + 1'b1;

                    end
                end


                STREAM_OUT: begin

                    if (m_axis_tvalid && m_axis_tready) begin

                        if (!output_imag) begin

                            output_imag <= 1'b1;

                        end else begin

                            output_imag <= 1'b0;

                            if (output_count == fft_n - 1'b1) begin

                                output_count <= '0;

                                done_reg <= 1'b1;
                                state <= IDLE;

                            end else begin

                                output_count <= output_count + 1'b1;

                            end
                        end
                    end
                end

                default: begin
                    state <= IDLE;
                end

            endcase
        end
    end

    // ------------------------------------------------------------
    // AXI-Lite write channel
    // ------------------------------------------------------------

    always_ff @(posedge clk_i or negedge rst_ni) begin

        if (!rst_ni) begin

            aw_pending <= 1'b0;
            w_pending  <= 1'b0;

            awaddr_reg <= '0;
            wdata_reg  <= '0;

            bvalid_reg <= 1'b0;

            reg_ctrl  <= '0;
            reg_fft_n <= 32'd64;

        end else begin

            if (s_axil_awvalid && s_axil_awready) begin
                awaddr_reg <= s_axil_awaddr;
                aw_pending <= 1'b1;
            end

            if (s_axil_wvalid && s_axil_wready) begin
                wdata_reg <= s_axil_wdata;
                w_pending <= 1'b1;
            end

            // Consume the start command after the FSM has
            // accepted it. This register has only one driver.
            if ((state == IDLE) && reg_ctrl[0]) begin
                reg_ctrl[0] <= 1'b0;
            end

            if (aw_pending && w_pending && !bvalid_reg) begin

                case (awaddr_reg[7:2])

                    // CTRL: bit 0 is a one-shot start command.
                    6'h00: begin
                        reg_ctrl <= wdata_reg;
                    end

                    // FFT length.
                    6'h02: begin
                        reg_fft_n <= wdata_reg;
                    end

                    default: begin
                    end

                endcase

                aw_pending <= 1'b0;
                w_pending  <= 1'b0;

                bvalid_reg <= 1'b1;

            end

            if (bvalid_reg && s_axil_bready)
                bvalid_reg <= 1'b0;

        end
    end

    // ------------------------------------------------------------
    // AXI-Lite read channel
    // ------------------------------------------------------------

    always_ff @(posedge clk_i or negedge rst_ni) begin

        if (!rst_ni) begin

            ar_pending   <= 1'b0;
            araddr_reg   <= '0;

            rvalid_reg   <= 1'b0;
            s_axil_rdata <= '0;

        end else begin

            if (s_axil_arvalid && s_axil_arready) begin
                araddr_reg <= s_axil_araddr;
                ar_pending <= 1'b1;
            end

            if (ar_pending && !rvalid_reg) begin

                case (araddr_reg[7:2])

                    6'h00: s_axil_rdata <= reg_ctrl;
                    6'h01: s_axil_rdata <= reg_status;
                    6'h02: s_axil_rdata <= reg_fft_n;

                    default:
                        s_axil_rdata <= 32'hDEAD_BEEF;

                endcase

                rvalid_reg <= 1'b1;
                ar_pending <= 1'b0;

            end

            if (rvalid_reg && s_axil_rready)
                rvalid_reg <= 1'b0;

        end
    end

endmodule

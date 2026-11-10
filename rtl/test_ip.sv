`timescale 1ns/1ps

module test_ip;

    logic clk_i;
    logic rst_ni;

    integer uart_fd;

    top u_top (
        .clk_i  (clk_i),
        .rst_ni (rst_ni)
    );

    // 100 MHz clock
    always #5 clk_i = ~clk_i;

    // ------------------------------------------------
    // Initialization
    // ------------------------------------------------

    initial begin

        clk_i  = 0;
        rst_ni = 0;

        uart_fd = $fopen("uart.log", "w");

        if (uart_fd == 0)
            $fatal(1, "[TB ERROR] Cannot open uart.log");

        $dumpfile("soc_waveform.vcd");
        $dumpvars(0, test_ip);

        #50;

        rst_ni = 1;

        $display("");
        $display("========================================");
        $display("       SOC SIMULATION STARTED");
        $display("========================================");
        $display("[TB] Reset released.");
        $display("[TB] Waiting for firmware...");
    end

    // ------------------------------------------------
    // UART and firmware termination monitor
    // ------------------------------------------------

    always @(posedge clk_i) begin

        if (rst_ni &&
            u_top.i_system_ram.req_i &&
            u_top.i_system_ram.we_i) begin

            // UART output
            if (u_top.i_system_ram.addr_i == 32'h20000000) begin

                $write("%c",
                    u_top.i_system_ram.wdata_i[7:0]);

                $fwrite(uart_fd, "%c",
                    u_top.i_system_ram.wdata_i[7:0]);

                $fflush(uart_fd);

            end

            // Firmware termination
            if (u_top.i_system_ram.addr_i == 32'h20000004) begin

                if (u_top.i_system_ram.wdata_i == 32'h0) begin

                    $display("");
                    $display("========================================");
                    $display("       SOC SIMULATION PASSED");
                    $display("========================================");

                    $display("[TB] Firmware exited successfully.");

                    $finish;

                end else begin

                    $fatal(1,
                        "[TB ERROR] Firmware returned error code: %h",
                        u_top.i_system_ram.wdata_i);

                end

            end

        end

    end

    // ------------------------------------------------
    // Watchdog
    // ------------------------------------------------

    initial begin

        #2000000;

        $fatal(1,
            "[TB ERROR] Firmware timeout! Simulation failed.");

    end

endmodule
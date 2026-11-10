module ram #(
    parameter int ADDR_WIDTH = 16, // Default: 64 KB address space (2^16 bytes)
    parameter int DATA_WIDTH = 32  // 32-bit data width matching PicoRV32 & AXI bus
)(
    input  logic                    clk_i,
    input  logic                    rst_ni,
    
    // Simple Memory-Mapped Slave Interface (or wire via AXI-Lite-to-Memory bridge)
    input  logic                    req_i,
    input  logic                    we_i,
    input  logic [ADDR_WIDTH-1:0]   addr_i,
    input  logic [DATA_WIDTH-1:0]   wdata_i,
    input  logic [DATA_WIDTH/8-1:0] wstrb_i, // Byte write enables (strobe)
    output logic [DATA_WIDTH-1:0]   rdata_o
);

    // Calculate depth based on 32-bit (4-byte) word alignment
    localparam int DEPTH = 1 << (ADDR_WIDTH - 2);

    // Core memory array storage
    logic [DATA_WIDTH-1:0] mem [DEPTH-1:0];

    // Preload firmware binary and initial data arrays for simulation
    initial begin
        $readmemh("firmware.hex", mem);
    end

    // Synchronous Read/Write Operation
    always_ff @(posedge clk_i) begin
        if (req_i) begin
            if (we_i) begin
                // Handle byte-level writes using wstrb (Byte Enables)
                if (wstrb_i[0]) mem[addr_id_safe][7:0]   <= wdata_i[7:0];
                if (wstrb_i[1]) mem[addr_id_safe][15:8]  <= wdata_i[15:8];
                if (wstrb_i[2]) mem[addr_id_safe][23:16] <= wdata_i[23:16];
                if (wstrb_i[3]) mem[addr_id_safe][31:24] <= wdata_i[31:24];
            end
            // Read word data out
            rdata_o <= mem[addr_id_safe];
        end
    end

    // Safe word-aligned index mapping (ignoring bottom 2 byte-offset bits)
    wire [$clog2(DEPTH)-1:0] addr_id_safe = addr_id_safe_func(addr_i);
    
    function automatic [$clog2(DEPTH)-1:0] addr_id_safe_func(input [ADDR_WIDTH-1:0] a);
        // Ensure bounds checking or shifting for word alignment
        return a[ADDR_WIDTH-1:2];
    endfunction

endmodule
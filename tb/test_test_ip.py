import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge
import random

class AxiLiteMaster:
    """Helper class to write and read AXI4-Lite control registers."""
    def __init__(self, dut):
        self.dut = dut
        dut.s_axil_awaddr.value = 0
        dut.s_axil_awvalid.value = 0
        dut.s_axil_wdata.value = 0
        dut.s_axil_wstrb.value = 0xF
        dut.s_axil_wvalid.value = 0
        dut.s_axil_bready.value = 0
        dut.s_axil_araddr.value = 0
        dut.s_axil_arvalid.value = 0
        dut.s_axil_rready.value = 0

    async def write(self, addr, data):
        dut = self.dut
        await RisingEdge(dut.clk_i)
        dut.s_axil_awaddr.value = addr
        dut.s_axil_awvalid.value = 1
        dut.s_axil_wdata.value = data
        dut.s_axil_wvalid.value = 1
        
        aw_done, w_done = False, False
        while not (aw_done and w_done):
            await RisingEdge(dut.clk_i)
            if dut.s_axil_awready.value and dut.s_axil_awvalid.value:
                dut.s_axil_awvalid.value = 0
                aw_done = True
            if dut.s_axil_wready.value and dut.s_axil_wvalid.value:
                dut.s_axil_wvalid.value = 0
                w_done = True

        while not dut.s_axil_bvalid.value:
            await RisingEdge(dut.clk_i)
        
        dut.s_axil_bready.value = 1
        await RisingEdge(dut.clk_i)
        dut.s_axil_bready.value = 0

    async def read(self, addr):
        dut = self.dut
        await RisingEdge(dut.clk_i)
        dut.s_axil_araddr.value = addr
        dut.s_axil_arvalid.value = 1
        dut.s_axil_rready.value = 1

        while not (dut.s_axil_arready.value and dut.s_axil_arvalid.value):
            await RisingEdge(dut.clk_i)
        dut.s_axil_arvalid.value = 0

        while not dut.s_axil_rvalid.value:
            await RisingEdge(dut.clk_i)
            
        data = int(dut.s_axil_rdata.value)
        await RisingEdge(dut.clk_i)
        dut.s_axil_rready.value = 0
        return data


# Define structured test cases
test_cases = {
    1: {
        "description": "Default configuration check",
        "reg_len": 1,
        "reg_constant": 0,
        "values": [0, 5, 10, 100]
    },
    2: {
        "description": "Custom multiplier and additive constant",
        "reg_len": 5,
        "reg_constant": 10,
        "values": [1, 2, 20, 50]
    },
    3: {
        "description": "Large numbers and boundary overflow check",
        "reg_len": 255,
        "reg_constant": 4096,
        "values": [1000, 0xFFFF, 0xFFFFFFFF]
    }
}


@cocotb.test()
async def test_ip_dictionary_driven(dut):
    """Dictionary-driven verification suite for test_ip."""
    
    # 100 MHz Clock setup
    clock = Clock(dut.clk_i, 10, units="ns")
    cocotb.start_soon(clock.start())

    # Initialize signals & apply Reset
    dut.rst_ni.value = 0
    dut.s_axis_tdata.value = 0
    dut.s_axis_tvalid.value = 0
    dut.s_axis_tlast.value = 0
    dut.m_axis_tready.value = 1
    
    axil = AxiLiteMaster(dut)
    
    for _ in range(5):
        await RisingEdge(dut.clk_i)
    dut.rst_ni.value = 1
    await RisingEdge(dut.clk_i)

    # Execute each test case from the dictionary
    for tc_id, tc in test_cases.items():
        dut._log.info(f"Running Test Case {tc_id}: {tc['description']}")
        
        # Configure registers over AXI4-Lite
        await axil.write(0x00, tc["reg_len"])
        await axil.write(0x04, tc["reg_constant"])
        
        # Verify register readback
        assert await axil.read(0x00) == tc["reg_len"]
        assert await axil.read(0x04) == tc["reg_constant"]

        # Stream values through AXI4-Stream
        for idx, val in enumerate(tc["values"]):
            await RisingEdge(dut.clk_i)
            dut.s_axis_tdata.value = val
            dut.s_axis_tvalid.value = 1
            dut.s_axis_tlast.value = 1 if idx == len(tc["values"]) - 1 else 0

            # Wait for input handshake
            while not (dut.s_axis_tready.value and dut.s_axis_tvalid.value):
                await RisingEdge(dut.clk_i)

            await RisingEdge(dut.clk_i)
            dut.s_axis_tvalid.value = 0 # drop valid

            # Wait for output valid response
            while not dut.m_axis_tvalid.value:
                await RisingEdge(dut.clk_i)

            # Compute expected math with 32-bit wrap-around
            expected = ((val * tc["reg_len"]) + tc["reg_constant"]) & 0xFFFFFFFF
            actual = int(dut.m_axis_tdata.value)

            # Assert correctness
            assert actual == expected, \
                f"[TC {tc_id}] Mismatch for input {val}: got {actual}, expected {expected}"
            
            dut._log.info(f"  -> Input: {val} | Output: {actual} (Passed)")

    dut._log.info("All dictionary test cases passed successfully!")
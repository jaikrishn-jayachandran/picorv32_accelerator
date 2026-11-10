import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge
import random

class AxiLiteMaster:
    """Helper class to handle AXI4-Lite register write and read transactions."""
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


@cocotb.test()
async def test_fft_analysis_pipeline(dut):
    """Test suite for fft_analysis accelerator IP."""
    
    # 1. Start 100 MHz clock (fixed unit argument deprecation)
    clock = Clock(dut.clk_i, 10, unit="ns")
    cocotb.start_soon(clock.start())

    # 2. Initialize signals and apply active-low reset
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

    dut._log.info("Reset released. Configuring FFT block...")

    # 3. Configure FFT size N = 16 via AXI4-Lite (Offset 0x08)
    FFT_SIZE = 16
    await axil.write(0x08, FFT_SIZE)
    
    # Verify readback of FFT size
    read_size = await axil.read(0x08)
    assert read_size == FFT_SIZE, f"FFT size readback failed: got {read_size}, expected {FFT_SIZE}"
    dut._log.info(f"FFT Size successfully configured to {FFT_SIZE}")

    # 4. Generate test input data samples
    input_samples = [random.randint(1, 50) for _ in range(FFT_SIZE)]
    output_received = []

    # Coroutine to stream inputs into AXI-Stream slave
    async def driver():
        for i, val in enumerate(input_samples):
            dut.s_axis_tdata.value = val
            dut.s_axis_tvalid.value = 1
            dut.s_axis_tlast.value = 1 if (i == FFT_SIZE - 1) else 0

            # Wait for valid handshake on positive edge
            await RisingEdge(dut.clk_i)
            while not (dut.s_axis_tready.value and dut.s_axis_tvalid.value):
                await RisingEdge(dut.clk_i)
        
        dut.s_axis_tvalid.value = 0
        dut.s_axis_tlast.value = 0

    # Coroutine to capture outputs from AXI-Stream master cleanly
    async def monitor():
        while len(output_received) < FFT_SIZE:
            await RisingEdge(dut.clk_i)
            if dut.m_axis_tvalid.value and dut.m_axis_tready.value:
                output_received.append(int(dut.m_axis_tdata.value))

    # Start driver and monitor concurrently
    dut._log.info("Streaming input samples...")
    driver_task = cocotb.start_soon(driver())
    monitor_task = cocotb.start_soon(monitor())

    # Wait for completion
    await driver_task
    await monitor_task

    # 5. Verify computed output against expected model
    dut._log.info("Verifying computed spectrum output...")
    for i in range(FFT_SIZE):
        expected = (input_samples[i] * input_samples[i]) & 0xFFFFFFFF
        actual = output_received[i]
        assert actual == expected, \
            f"Mismatch at index {i}: input={input_samples[i]}, got {actual}, expected {expected}"
        dut._log.info(f"  Sample [{i}]: input={input_samples[i]} -> output={actual} (Verified)")

    dut._log.info("All FFT accelerator verification tests passed successfully!")

import cocotb

from cocotb.clock import Clock
from cocotb.triggers import (
    FallingEdge,
    RisingEdge,
    Timer,
    with_timeout,
)


# ============================================================
# SoC memory map
# ============================================================

RAM_BASE       = 0x00000000
UART_DEBUG     = 0x20000000
SIM_EXIT       = 0x20000004

CLOCK_PERIOD_NS = 10
RESET_TIME_NS   = 50
TIMEOUT_NS      = 2_000_000

FFT_N = 64
FFT_OUTPUT_TRANSFERS = 2 * FFT_N
FFT_DATA_WIDTH = 32


# ============================================================
# Utility functions
# ============================================================

def to_signed(value, width=32):
    """Convert an unsigned bit-vector value to a signed integer."""
    sign_bit = 1 << (width - 1)

    if value & sign_bit:
        value -= 1 << width

    return value


def save_uart_log(output):
    with open("uart.log", "w", encoding="utf-8") as f:
        f.write(output)


def save_fft_results(inputs, outputs, tlast_positions):
    """Save captured AXI-Stream data to fft_results.txt."""

    with open("fft_results.txt", "w", encoding="utf-8") as f:

        f.write("========================================\n")
        f.write("       PICORV32 FFT ACCELERATOR\n")
        f.write("             STREAM REPORT\n")
        f.write("========================================\n\n")

        f.write("INPUT SAMPLES\n")
        f.write("----------------------------------------\n")

        for index, value in enumerate(inputs):
            f.write(f"Input[{index:02d}] = {value}\n")

        f.write("\nFFT OUTPUT (COMPLEX)\n")
        f.write("----------------------------------------\n")

        for index in range(FFT_N):
            real = outputs[2 * index]
            imag = outputs[2 * index + 1]

            f.write(
                f"FFT[{index:02d}] = "
                f"{real} + j({imag})\n"
            )

        f.write("\nSTREAM SUMMARY\n")
        f.write("----------------------------------------\n")

        f.write(f"Input transfers  : {len(inputs)}\n")
        f.write(f"Output transfers : {len(outputs)}\n")
        f.write(f"FFT length       : {FFT_N}\n")
        f.write(f"Expected outputs : {FFT_OUTPUT_TRANSFERS}\n")
        f.write(f"TLAST positions  : {tlast_positions}\n")

        f.write("\n========================================\n")
        f.write("              END OF REPORT\n")
        f.write("========================================\n")


# ============================================================
# Firmware + FFT integration test
# ============================================================

@cocotb.test()
async def firmware_boot_test(dut):

    dut._log.info("========================================")
    dut._log.info(" PicoRV32 SoC + FFT Integration Test")
    dut._log.info("========================================")

    # --------------------------------------------------------
    # Clock and reset
    # --------------------------------------------------------

    dut.clk_i.value = 0
    dut.rst_ni.value = 0

    dut.fft_s_axis_tdata.value = 0
    dut.fft_s_axis_tvalid.value = 0
    dut.fft_s_axis_tlast.value = 0

    dut.fft_m_axis_tready.value = 1

    cocotb.start_soon(
        Clock(
            dut.clk_i,
            CLOCK_PERIOD_NS,
            unit="ns",
        ).start()
    )

    await Timer(RESET_TIME_NS, unit="ns")
    dut.rst_ni.value = 1

    dut._log.info("[RESET] Reset released")
    dut._log.info("[CPU] Waiting for firmware execution...")

    # --------------------------------------------------------
    # Test observations
    # --------------------------------------------------------

    uart_output = []
    sample_writes = {}

    fft_inputs_accepted = []
    fft_outputs = []
    fft_tlast_positions = []

    exit_code = None
    exit_write_seen = False

    stream_done = False
    output_done = False

    ram = dut.i_system_ram

    # --------------------------------------------------------
    # FFT AXI-Stream input driver
    # --------------------------------------------------------

    async def fft_input_driver():

        nonlocal stream_done

        dut._log.info("[FFT] Waiting for input ready...")

        for index in range(FFT_N):

            await FallingEdge(dut.clk_i)

            dut.fft_s_axis_tdata.value = index
            dut.fft_s_axis_tvalid.value = 1
            dut.fft_s_axis_tlast.value = (
                1 if index == FFT_N - 1 else 0
            )

            while True:

                if int(dut.fft_s_axis_tready.value):

                    # Transfer is accepted on the next rising edge.
                    await RisingEdge(dut.clk_i)

                    fft_inputs_accepted.append(index)

                    dut._log.info(
                        "[FFT INPUT] Accepted sample %d = %d",
                        index,
                        index,
                    )

                    break

                await FallingEdge(dut.clk_i)

        # Deassert input only after the last transfer.
        await FallingEdge(dut.clk_i)

        dut.fft_s_axis_tvalid.value = 0
        dut.fft_s_axis_tlast.value = 0
        dut.fft_s_axis_tdata.value = 0

        stream_done = True

        dut._log.info(
            "[FFT] Input complete: %d/%d samples",
            len(fft_inputs_accepted),
            FFT_N,
        )

    # --------------------------------------------------------
    # FFT AXI-Stream output monitor
    # --------------------------------------------------------

    async def fft_output_monitor():

        nonlocal output_done

        while len(fft_outputs) < FFT_OUTPUT_TRANSFERS:

            await FallingEdge(dut.clk_i)

            valid = int(dut.fft_m_axis_tvalid.value)
            ready = int(dut.fft_m_axis_tready.value)

            if valid and ready:

                raw_data = int(dut.fft_m_axis_tdata.value)
                data = to_signed(raw_data, FFT_DATA_WIDTH)

                last = int(dut.fft_m_axis_tlast.value)

                fft_outputs.append(data)

                if last:
                    fft_tlast_positions.append(
                        len(fft_outputs) - 1
                    )

                dut._log.info(
                    "[FFT OUTPUT] Transfer=%d Data=%d TLAST=%d",
                    len(fft_outputs) - 1,
                    data,
                    last,
                )

                # This transfer is accepted at the rising edge.
                await RisingEdge(dut.clk_i)

        output_done = True

        dut._log.info(
            "[FFT] Output complete: %d/%d transfers",
            len(fft_outputs),
            FFT_OUTPUT_TRANSFERS,
        )

    # --------------------------------------------------------
    # Firmware memory-mapped write monitor
    # --------------------------------------------------------

    async def firmware_monitor():

        nonlocal exit_code
        nonlocal exit_write_seen

        while True:

            await FallingEdge(dut.clk_i)

            # Snapshot the transaction before the active edge.
            req = int(ram.req_i.value)
            we = int(ram.we_i.value)

            if req and we:

                addr = int(ram.addr_i.value)
                data = int(ram.wdata_i.value)

                # The write takes effect at the next rising edge.
                await RisingEdge(dut.clk_i)

                # UART debug output.
                if addr == UART_DEBUG:

                    char = chr(data & 0xFF)
                    uart_output.append(char)

                    dut._log.info(
                        "[UART] %s",
                        repr(char),
                    )

                # Firmware sample array:
                # RAM + 0x1000 through RAM + 0x10FF.
                elif (
                    RAM_BASE + 0x1000
                    <= addr
                    < RAM_BASE + 0x1100
                ):

                    index = (
                        addr - (RAM_BASE + 0x1000)
                    ) // 4

                    sample_writes[index] = data

                # Firmware simulation exit.
                elif addr == SIM_EXIT:

                    exit_code = data
                    exit_write_seen = True

                    dut._log.info(
                        "[SIM EXIT] Firmware exit code: %d",
                        exit_code,
                    )

            # Stop only after all activities have completed.
            if (
                exit_write_seen
                and stream_done
                and output_done
            ):
                break

    # --------------------------------------------------------
    # Start concurrent processes
    # --------------------------------------------------------

    input_task = cocotb.start_soon(fft_input_driver())
    output_task = cocotb.start_soon(fft_output_monitor())

    try:

        await with_timeout(
            firmware_monitor(),
            TIMEOUT_NS,
            "ns",
        )

        await with_timeout(
            input_task,
            TIMEOUT_NS,
            "ns",
        )

        await with_timeout(
            output_task,
            TIMEOUT_NS,
            "ns",
        )

    except Exception as error:

        output = "".join(uart_output)

        dut._log.error("[TIMEOUT] Test did not complete")
        dut._log.error("UART output:\n%s", output)

        dut._log.error(
            "RAM samples written: %d/%d",
            len(sample_writes),
            FFT_N,
        )

        dut._log.error(
            "FFT input accepted: %d/%d",
            len(fft_inputs_accepted),
            FFT_N,
        )

        dut._log.error(
            "FFT output received: %d/%d",
            len(fft_outputs),
            FFT_OUTPUT_TRANSFERS,
        )

        dut._log.error(
            "Firmware exit observed: %s",
            exit_write_seen,
        )

        dut._log.error(
            "Input driver completed: %s",
            stream_done,
        )

        dut._log.error(
            "Output monitor completed: %s",
            output_done,
        )

        raise AssertionError(
            f"SoC/FFT integration test failed: {error}"
        )

    # --------------------------------------------------------
    # Save firmware UART output
    # --------------------------------------------------------

    output = "".join(uart_output)

    save_uart_log(output)

    dut._log.info("")
    dut._log.info("============== FIRMWARE OUTPUT ==============")
    dut._log.info("\n%s", output)
    dut._log.info("==============================================")

    # --------------------------------------------------------
    # Check firmware output
    # --------------------------------------------------------

    required_messages = [
        "[FIRMWARE] Booting RISC-V SoC...",
        "[INPUT] Initializing sample array...",
        "[INPUT] RAM verification passed!",
        "[FFT] Starting accelerator...",
        "[FFT] Computation completed!",
        "[FIRMWARE] Test sequence completed successfully!",
    ]

    for message in required_messages:

        assert message in output, (
            f"Missing expected firmware message: {message}"
        )

    dut._log.info("[FIRMWARE] UART messages verified")

    # --------------------------------------------------------
    # Check RAM initialization
    # --------------------------------------------------------

    dut._log.info("[RAM] Checking sample initialization...")

    assert len(sample_writes) == FFT_N, (
        f"Expected {FFT_N} RAM writes, "
        f"observed {len(sample_writes)}"
    )

    for index in range(FFT_N):

        assert index in sample_writes, (
            f"Missing RAM write for sample index {index}"
        )

        assert sample_writes[index] == index, (
            f"RAM mismatch at index {index}: "
            f"expected {index}, got {sample_writes[index]}"
        )

    dut._log.info(
        "[RAM] All %d sample writes verified",
        FFT_N,
    )

    # --------------------------------------------------------
    # Check FFT input
    # --------------------------------------------------------

    assert stream_done, (
        "FFT input transmission did not complete"
    )

    assert len(fft_inputs_accepted) == FFT_N, (
        f"Expected {FFT_N} accepted input samples, "
        f"received {len(fft_inputs_accepted)}"
    )

    assert fft_inputs_accepted == list(range(FFT_N)), (
        "FFT input sequence mismatch"
    )

    dut._log.info("[FFT] Input handshakes verified")

    # --------------------------------------------------------
    # Check FFT output transfers
    # --------------------------------------------------------

    dut._log.info("[FFT] Checking output transfers...")

    assert output_done, (
        "FFT output monitor did not complete"
    )

    assert len(fft_outputs) == FFT_OUTPUT_TRANSFERS, (
        f"Expected {FFT_OUTPUT_TRANSFERS} output transfers, "
        f"received {len(fft_outputs)}"
    )

    real_values = fft_outputs[0::2]
    imag_values = fft_outputs[1::2]

    assert len(real_values) == FFT_N
    assert len(imag_values) == FFT_N

    dut._log.info(
        "[FFT] Received %d real and %d imaginary values",
        len(real_values),
        len(imag_values),
    )

    # --------------------------------------------------------
    # Check TLAST
    # --------------------------------------------------------

    assert fft_tlast_positions == [
        FFT_OUTPUT_TRANSFERS - 1
    ], (
        f"Expected TLAST only at output index "
        f"{FFT_OUTPUT_TRANSFERS - 1}, "
        f"observed at {fft_tlast_positions}"
    )

    dut._log.info("[FFT] TLAST position verified")

    # --------------------------------------------------------
    # Check firmware simulation exit
    # --------------------------------------------------------

    assert exit_write_seen, (
        "Firmware did not trigger simulation exit"
    )

    assert exit_code == 1, (
        f"Expected firmware exit code 1, got {exit_code}"
    )

    # --------------------------------------------------------
    # Save FFT results
    # --------------------------------------------------------

    save_fft_results(
        fft_inputs_accepted,
        fft_outputs,
        fft_tlast_positions,
    )

    dut._log.info(
        "[FILES] Saved uart.log and fft_results.txt"
    )

    # --------------------------------------------------------
    # Final report
    # --------------------------------------------------------

    dut._log.info("")
    dut._log.info("==============================================")
    dut._log.info("             FFT STREAM RESULTS")
    dut._log.info("==============================================")

    dut._log.info("INPUT SAMPLES:")

    for i, value in enumerate(fft_inputs_accepted):
        dut._log.info(
            "Input[%02d] = %d",
            i,
            value,
        )

    dut._log.info("")
    dut._log.info("FFT OUTPUT (REAL + IMAGINARY):")

    for i in range(FFT_N):

        real = fft_outputs[2 * i]
        imag = fft_outputs[2 * i + 1]

        dut._log.info(
            "FFT[%02d] = %d + j(%d)",
            i,
            real,
            imag,
        )

    dut._log.info("")
    dut._log.info("==============================================")
    dut._log.info(" ALL SOC + FFT INTEGRATION CHECKS PASSED")
    dut._log.info("==============================================")

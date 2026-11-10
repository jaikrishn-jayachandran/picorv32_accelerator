# Compile assembly startup and C code together
riscv32-unknown-elf-gcc -march=rv32i -mabi=ilp32 -ffreestanding -nostdlib \
    -T sw/sections.ld sw/start.s sw/firmware.c -o sw/firmware.elf

# Convert ELF binary to raw binary machine code
riscv32-unknown-elf-objcopy -O binary sw/firmware.elf sw/firmware.bin

# Convert binary to 32-bit hex format readable by $readmemh in ram.sv
python3 -c '
with open("sw/firmware.bin", "rb") as f:
    data = f.read()
with open("firmware.hex", "w") as f:
    for i in range(0, len(data), 4):
        chunk = data[i:i+4].ljust(4, b"\x00")
        f.write(f"{int.from_bytes(chunk, \"little\"):08x}\n")
'
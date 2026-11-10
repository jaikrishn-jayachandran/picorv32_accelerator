MEMORY
{
    RAM (rwx) : ORIGIN = 0x00000000, LENGTH = 64K
}

SECTIONS
{
    .text : { *(.text) } > RAM
    .data : { *(.data) } > RAM
    .bss  : { *(.bss)  } > RAM
}
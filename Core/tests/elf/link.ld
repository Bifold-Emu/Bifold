/* One R+X PT_LOAD segment starting at offset 0 of the 3DS process image (0x00100000). */
ENTRY(_start)
PHDRS { text PT_LOAD FLAGS(5); }
SECTIONS {
  . = 0x0;
  .text : { *(.text.start) *(.text*) *(.rodata*) } :text
  /DISCARD/ : { *(.ARM.exidx*) *(.comment) }
}

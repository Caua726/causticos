// cdvrspec_data.s — embeds raw .cdvrspec text blobs into the kernel.
//
// Each driver contributes: a pair of labels delimiting its spec bytes
// (.cdvrspec_data), plus two .quad entries in .cdvrspec_index holding
// those labels' addresses. At boot the kernel iterates
// __start_cdvrspec_index .. __stop_cdvrspec_index (emitted automatically
// by caustic-ld for any custom section) reading pairs of (start, end)
// pointers and handing each byte range to the parser in specparse.cst.

.section .cdvrspec_data
.global _cdvrspec_dummy_start
.global _cdvrspec_dummy_end
.global _cdvrspec_e1000_start
.global _cdvrspec_e1000_end
.global _cdvrspec_kbd_start
.global _cdvrspec_kbd_end
.global _cdvrspec_mouse_start
.global _cdvrspec_mouse_end
.global _cdvrspec_ahci_start
.global _cdvrspec_ahci_end
.global _cdvrspec_vtablet_start
.global _cdvrspec_vtablet_end
.global _cdvrspec_vnet_start
.global _cdvrspec_vnet_end
_cdvrspec_dummy_start:
.incbin "kernel/drivers/dummy.cdvrspec"
_cdvrspec_dummy_end:
_cdvrspec_e1000_start:
.incbin "kernel/drivers/e1000.cdvrspec"
_cdvrspec_e1000_end:
_cdvrspec_kbd_start:
.incbin "kernel/drivers/kbd.cdvrspec"
_cdvrspec_kbd_end:
_cdvrspec_mouse_start:
.incbin "kernel/drivers/mouse.cdvrspec"
_cdvrspec_mouse_end:
_cdvrspec_ahci_start:
.incbin "kernel/drivers/ahci.cdvrspec"
_cdvrspec_ahci_end:
_cdvrspec_vtablet_start:
.incbin "kernel/drivers/vtablet.cdvrspec"
_cdvrspec_vtablet_end:
_cdvrspec_vnet_start:
.incbin "kernel/drivers/vnet.cdvrspec"
_cdvrspec_vnet_end:

.section .cdvrspec_index
.quad _cdvrspec_dummy_start
.quad _cdvrspec_dummy_end
.quad _cdvrspec_e1000_start
.quad _cdvrspec_e1000_end
.quad _cdvrspec_kbd_start
.quad _cdvrspec_kbd_end
.quad _cdvrspec_mouse_start
.quad _cdvrspec_mouse_end
.quad _cdvrspec_ahci_start
.quad _cdvrspec_ahci_end
.quad _cdvrspec_vtablet_start
.quad _cdvrspec_vtablet_end
.quad _cdvrspec_vnet_start
.quad _cdvrspec_vnet_end

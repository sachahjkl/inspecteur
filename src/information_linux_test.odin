package inspecteur

import "core:testing"

@(test)
os_release_gives_the_pretty_name :: proc(t: ^testing.T) {
	testing.expect_value(t, os_release_name("NAME=NixOS\nVERSION=\"26.05 (Yarara)\"\nPRETTY_NAME=\"NixOS 26.05 (Yarara)\"\n"), "NixOS 26.05 (Yarara)")
	testing.expect_value(t, os_release_name("NAME='Debian GNU/Linux'\nVERSION='13'\n"), "Debian GNU/Linux 13")
}

@(test)
pci_ids_name_a_device_under_its_vendor :: proc(t: ^testing.T) {
	ids := "# comment\n10de  NVIDIA Corporation\n\t2684  AD102 [GeForce RTX 4090]\n\t\t1043 88e2  subsystem\n\t2783  AD104 [GeForce RTX 4070 SUPER]\n1002  Advanced Micro Devices, Inc. [AMD/ATI]\n\t2783  not this one\n"
	v, d := pci_names(ids, "10de", "2783")
	testing.expect_value(t, v, "NVIDIA Corporation")
	testing.expect_value(t, d, "AD104 [GeForce RTX 4070 SUPER]")
	v, d = pci_names(ids, "10DE", "9999")
	testing.expect_value(t, v, "NVIDIA Corporation")
	testing.expect_value(t, d, "")
}

@(test)
an_edid_names_its_monitor :: proc(t: ^testing.T) {
	edid: [128]u8
	// "GSM": G=7, S=19, M=13
	maker := u16(7) << 10 | u16(19) << 5 | u16(13)
	edid[8], edid[9] = u8(maker >> 8), u8(maker)
	testing.expect_value(t, edid_name(edid[:]), "GSM")
	d := edid[72:][:18]
	d[3] = 0xFC
	copy(d[5:], "LG HDR 4K\n   ")
	testing.expect_value(t, edid_name(edid[:]), "LG HDR 4K")
}

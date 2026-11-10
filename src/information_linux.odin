package inspecteur

// What the system is, on Linux: /etc/os-release, uname, /sys/class/dmi/id, /proc/cpuinfo, /sys/bus/pci/devices (the
// GPUs; their names from pci.ids when the system has it, else their vendor's name and the device's number),
// /proc/self/mountinfo and statfs, /sys/class/drm (the screens, their EDID), /sys/class/power_supply, the session's
// environment.

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/linux"

// The lists of PCI devices' names, where the systems keep them.
PCI_IDS_PATHS :: [?]string{"/run/current-system/sw/share/hwdata/pci.ids", "/usr/share/hwdata/pci.ids", "/usr/share/misc/pci.ids", "/usr/share/pci.ids"}
// The PCI class of a display controller (VGA, 3D, other): the first byte of the class.
PCI_CLASS_DISPLAY :: 0x03
// The bytes of an EDID's block that are read (the base block holds the monitor's name).
EDID_BASE_BYTES :: 128

// Reads everything; its texts in context.allocator (the reading's arena).
info_read :: proc(s: ^Info_Static) {
	a := context.allocator
	if data, err := os.read_entire_file("/etc/os-release", context.temp_allocator); err == nil {
		s.os_name = strings.clone(os_release_name(string(data)), a)
	}
	uts: linux.UTS_Name
	if linux.uname(&uts) == .NONE {
		s.kernel = strings.clone(fmt.tprintf("Linux %s (%s)", cstr(uts.release[:]), cstr(uts.version[:])), a)
		s.arch = strings.clone(cstr(uts.machine[:]), a)
		s.hostname = strings.clone(cstr(uts.nodename[:]), a)
	}
	dmi :: proc(name: string) -> string { return read_text(fmt.tprintf("/sys/class/dmi/id/%s", name)) }
	s.computer = strings.clone(joined(dmi("sys_vendor"), dmi("product_name")), a)
	s.board = strings.clone(joined(dmi("board_vendor"), dmi("board_name")), a)
	s.firmware = strings.clone(joined(dmi("bios_vendor"), dmi("bios_version"), dmi("bios_date")), a)
	s.desktop = strings.clone(os.get_env("XDG_CURRENT_DESKTOP", context.temp_allocator), a)
	s.session = strings.clone(os.get_env("XDG_SESSION_TYPE", context.temp_allocator), a)
	if wl := os.get_env("WAYLAND_DISPLAY", context.temp_allocator); wl != "" {
		s.display = strings.clone(fmt.tprintf("Wayland (%s)", wl), a)
	} else if x := os.get_env("DISPLAY", context.temp_allocator); x != "" {
		s.display = strings.clone(fmt.tprintf("X11 (%s)", x), a)
	}
	if data, err := os.read_entire_file("/proc/cpuinfo", context.temp_allocator); err == nil {
		s.cpu = parse_cpuinfo(string(data))   // (its model in context.allocator: the arena)
	}
	gpus_find(s)
	filesystems_find(s)
	screens_find(s)
	batteries_find(s)
}

// A C string of a fixed buffer, up to its first NUL.
@(private = "file")
cstr :: proc(b: []u8) -> string {
	n := 0
	for n < len(b) && b[n] != 0 { n += 1 }
	return string(b[:n])
}

// The words that are known, apart by spaces ("" when none is; a firmware's "To be filled by O.E.M." is not known).
@(private = "file")
joined :: proc(parts: ..string) -> string {
	known := make([dynamic]string, context.temp_allocator)
	for p in parts {
		if p == "" || strings.contains(p, "O.E.M.") || p == "Default string" || p == "System Product Name" || p == "System manufacturer" { continue }
		append(&known, p)
	}
	return strings.join(known[:], " ", context.temp_allocator)
}

// The system's name from /etc/os-release: PRETTY_NAME, else NAME and VERSION.
os_release_name :: proc(text: string) -> string {
	pretty, name, version: string
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		eq := strings.index_byte(line, '=')
		if eq < 0 { continue }
		v := strings.trim_space(line[eq + 1:])
		if len(v) >= 2 && (v[0] == '"' || v[0] == '\'') && v[len(v) - 1] == v[0] { v = v[1:len(v) - 1] }
		switch line[:eq] {
		case "PRETTY_NAME": pretty = v
		case "NAME":        name = v
		case "VERSION":     version = v
		}
	}
	if pretty != "" { return pretty }
	return strings.trim_space(strings.join({name, version}, " ", context.temp_allocator))
}

////////////////////////////////
// GPUs

@(private = "file")
gpus_find :: proc(s: ^Info_Static) {
	a := context.allocator
	dir := "/sys/bus/pci/devices"
	fis, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil { return }
	ids_text := ""
	for p in PCI_IDS_PATHS {
		if data, rerr := os.read_entire_file(p, context.temp_allocator); rerr == nil { ids_text = string(data); break }
	}
	for fi in fis {
		class := strconv.parse_u64(strings.trim_prefix(read_text(fmt.tprintf("%s/%s/class", dir, fi.name)), "0x"), 16) or_else 0
		if class >> 16 != PCI_CLASS_DISPLAY { continue }
		vendor := strings.trim_prefix(read_text(fmt.tprintf("%s/%s/vendor", dir, fi.name)), "0x")
		device := strings.trim_prefix(read_text(fmt.tprintf("%s/%s/device", dir, fi.name)), "0x")
		driver := ""
		if target, lerr := os.read_link(fmt.tprintf("%s/%s/driver", dir, fi.name), context.temp_allocator); lerr == nil {
			driver = target[strings.last_index_byte(target, '/') + 1:]
		}
		vendor_name, device_name := pci_names(ids_text, vendor, device)
		if vendor_name == "" { vendor_name = pci_vendor_known(vendor) }
		name := strings.trim_space(strings.join({vendor_name, device_name}, " ", context.temp_allocator))
		if name == "" { name = "Display controller" }
		append(&s.gpus, Info_Gpu{
			name = strings.clone(name, a), vendor = strings.clone(vendor_name, a), named = device_name != "", ids = strings.clone(fmt.tprintf("%s:%s", vendor, device), a),
			driver = strings.clone(driver, a), slot = strings.clone(fi.name, a),
		})
	}
}

// The vendor's and the device's names in pci.ids: a vendor at the start of a line ("10de  NVIDIA Corporation"), its
// devices under it after a tab ("\t2684  AD102 [GeForce RTX 4090]").
pci_names :: proc(ids, vendor, device: string) -> (vendor_name, device_name: string) {
	rest := ids
	in_vendor := false
	for line in strings.split_lines_iterator(&rest) {
		if len(line) == 0 || line[0] == '#' { continue }
		if line[0] != '\t' {
			if in_vendor { return }
			if len(line) > 6 && strings.equal_fold(line[:4], vendor) && line[4] == ' ' {
				in_vendor = true
				vendor_name = strings.trim_space(line[4:])
			}
			continue
		}
		if in_vendor && len(line) > 7 && line[1] != '\t' && strings.equal_fold(line[1:5], device) {
			device_name = strings.trim_space(line[5:])
			return
		}
	}
	return
}

// The GPU makers' names when the system has no pci.ids.
@(private = "file")
pci_vendor_known :: proc(vendor: string) -> string {
	switch strings.to_lower(vendor, context.temp_allocator) {
	case "10de": return "NVIDIA"
	case "1002": return "AMD"
	case "8086": return "Intel"
	case "1af4": return "Virtio"
	case "15ad": return "VMware"
	case "1234": return "QEMU"
	case "5143": return "Qualcomm"
	}
	return ""
}

////////////////////////////////
// File systems

// The file systems of storage (not the kernel's, not a bind mount of a part of another), with their size and free room.
@(private = "file")
filesystems_find :: proc(s: ^Info_Static) {
	a := context.allocator
	data, err := os.read_entire_file("/proc/self/mountinfo", context.temp_allocator)
	if err != nil { return }
	seen := make(map[string]bool, 16, context.temp_allocator)
	rest := string(data)
	for line in strings.split_lines_iterator(&rest) {
		m, ok := parse_mountinfo_line(line)
		if !ok || !storage_kind(m.kind) || m.device in seen { continue }
		seen[m.device] = true
		st: linux.Stat_FS
		path := strings.clone_to_cstring(m.mount, context.temp_allocator)
		if linux.statfs(path, &st) != .NONE { continue }
		unit := u64(st.frsize > 0 ? st.frsize : st.bsize)
		append(&s.fss, Info_Fs{
			mount = strings.clone(m.mount, a), device = strings.clone(m.device, a), kind = strings.clone(m.kind, a),
			size = u64(st.blocks) * unit, free = u64(st.bavail) * unit,
		})
	}
}

Mount_Line :: struct { mount, kind, device, root: string }

// A line of /proc/self/mountinfo: "36 35 98:0 /mnt1 /mnt/parent rw,noatime master:1 - ext3 /dev/root rw,errors=continue".
// The mount point is the fifth field (spaces in it are "\040"); after " - ": the type and the device.
parse_mountinfo_line :: proc(line: string) -> (m: Mount_Line, ok: bool) {
	dash := strings.index(line, " - ")
	if dash < 0 { return }
	head := strings.fields(line[:dash], context.temp_allocator)
	tail := strings.fields(line[dash + 3:], context.temp_allocator)
	if len(head) < 5 || len(tail) < 2 { return }
	mount, _ := strings.replace_all(head[4], "\\040", " ", context.temp_allocator)
	return {mount = mount, root = head[3], kind = tail[0], device = tail[1]}, true
}

// The file systems that hold files on a disk (or a network's); not the kernel's own (proc, sysfs, tmpfs...).
storage_kind :: proc(kind: string) -> bool {
	switch kind {
	case "ext2", "ext3", "ext4", "btrfs", "xfs", "zfs", "f2fs", "vfat", "exfat", "ntfs", "ntfs3", "fuseblk", "bcachefs", "jfs", "reiserfs", "nfs", "nfs4", "cifs", "smb3", "iso9660", "udf":
		return true
	}
	return false
}

////////////////////////////////
// Screens

@(private = "file")
screens_find :: proc(s: ^Info_Static) {
	a := context.allocator
	dir := "/sys/class/drm"
	fis, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil { return }
	for fi in fis {
		// (a connector: card1-DP-2; the card itself and renderD128 have no status)
		dash := strings.index_byte(fi.name, '-')
		if !strings.has_prefix(fi.name, "card") || dash < 0 { continue }
		if read_text(fmt.tprintf("%s/%s/status", dir, fi.name)) != "connected" { continue }
		mode := ""
		if modes, merr := os.read_entire_file(fmt.tprintf("%s/%s/modes", dir, fi.name), context.temp_allocator); merr == nil {
			text := string(modes)
			if nl := strings.index_byte(text, '\n'); nl >= 0 { text = text[:nl] }
			mode = text
		}
		name := ""
		if edid, eerr := os.read_entire_file(fmt.tprintf("%s/%s/edid", dir, fi.name), context.temp_allocator); eerr == nil {
			name = edid_name(edid)
		}
		append(&s.screens, Info_Screen{connector = strings.clone(fi.name[dash + 1:], a), name = strings.clone(name, a), mode = strings.clone(strings.trim_space(mode), a)})
	}
}

// The monitor's name in its EDID: its maker's three letters (bytes 8 and 9), and the text of its name's descriptor
// (one of the four 18-byte descriptors from byte 54 whose tag, its fourth byte, is 0xFC).
edid_name :: proc(edid: []u8) -> string {
	if len(edid) < EDID_BASE_BYTES { return "" }
	maker := u16(edid[8]) << 8 | u16(edid[9])
	letters := [3]u8{u8('@' + (maker >> 10) & 31), u8('@' + (maker >> 5) & 31), u8('@' + maker & 31)}
	for k in 0 ..< 4 {
		d := edid[54 + 18 * k:][:18]
		if d[0] != 0 || d[1] != 0 || d[3] != 0xFC { continue }
		text := string(d[5:18])
		if nl := strings.index_byte(text, '\n'); nl >= 0 { text = text[:nl] }
		return strings.trim_space(text)
	}
	return string(letters[:]) == "@@@" ? "" : strings.clone(string(letters[:]), context.temp_allocator)
}

////////////////////////////////
// Batteries

@(private = "file")
batteries_find :: proc(s: ^Info_Static) {
	a := context.allocator
	dir := "/sys/class/power_supply"
	fis, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil { return }
	for fi in fis {
		file :: proc(dir, name, f: string) -> string { return read_text(fmt.tprintf("%s/%s/%s", dir, name, f)) }
		if file(dir, fi.name, "type") != "Battery" { continue }
		number :: proc(text: string) -> f64 { return strconv.parse_f64(text) or_else 0 }
		full := number(file(dir, fi.name, "energy_full"))
		design := number(file(dir, fi.name, "energy_full_design"))
		if full == 0 {
			full = number(file(dir, fi.name, "charge_full"))
			design = number(file(dir, fi.name, "charge_full_design"))
		}
		b := Info_Battery{
			name = strings.clone(fi.name, a), status = strings.clone(file(dir, fi.name, "status"), a),
			model = strings.clone(joined(file(dir, fi.name, "manufacturer"), file(dir, fi.name, "model_name")), a),
			technology = strings.clone(file(dir, fi.name, "technology"), a),
			capacity = int(number(file(dir, fi.name, "capacity"))), health = -1,
		}
		if design > 0 && full > 0 { b.health = int(100 * full / design + 0.5) }
		append(&s.batteries, b)
	}
}
